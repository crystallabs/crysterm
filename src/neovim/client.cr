require "msgpack"

module Crysterm
  # Embedding Neovim: a child `nvim --embed` process spoken to over
  # msgpack-RPC (`Neovim::Client`), and the translation of Crysterm key
  # events into Neovim's key notation (`Neovim::Keys`), from which an
  # application or a widget offers "real vim" editing.
  #
  # ```
  # if Crysterm::Neovim.available?
  #   nvim = Crysterm::Neovim::Client.new args: ["--clean"]
  #   nvim.request("nvim_eval", "1+2").as_i # => 3
  #   nvim.close
  # end
  # ```
  module Neovim
    # The executable a `Client` runs when none is given: a name looked up in
    # `PATH`, or a path.
    class_property executable : String = "nvim"

    # The full path of the Neovim executable *name*, or `nil` when there is
    # none to run.
    def self.find_executable(name : String = executable) : String?
      Process.find_executable name
    end

    # Whether Neovim can be run: the executable *name* is found.
    def self.available?(name : String = executable) : Bool
      !find_executable(name).nil?
    end

    # Raised by `Client#request` when Neovim answers with an error, and by a
    # request or notification that cannot reach Neovim because its process
    # is gone.
    class Error < Exception
      # Neovim's error type (`0` an exception, `1` a validation error, as
      # `nvim_get_api_info` lists them), or `nil` for an error of the
      # connection rather than an answer.
      getter type : Int32?

      def initialize(message : String, @type : Int32? = nil)
        super message
      end
    end

    # A Neovim process started with `--embed` and the msgpack-RPC channel on
    # its standard input and output — the host side of Neovim's API
    # (`:help api`, `:help rpc`).
    #
    # `#request` calls an API function and returns its result, parking only
    # the calling fiber until the answer arrives; `#notify` calls one without
    # waiting. What Neovim sends on its own — notifications (`redraw` for an
    # attached UI, `nvim_buf_lines_event`, whatever `rpcnotify()` sends) and
    # requests (`rpcrequest()`) — reaches the blocks given to
    # `#on_notification` and `#on_request`, in the order Neovim sent it, on a
    # dispatch fiber of the client's own, so a handler may itself make
    # requests. `#on_exit` blocks run once the process has ended, for
    # whatever reason; `#close` ends it.
    #
    # Values cross as `MessagePack::Type`: strings, integers, floats,
    # booleans, `nil`, arrays and string-keyed hashes. Neovim's handle types
    # (`Buffer`, `Window`, `Tabpage`, msgpack extension types) arrive as their
    # `Int64` handle, which Neovim accepts back wherever it takes one (`0`
    # names the current one).
    #
    # The process is not stopped when the host exits without `#close`: its
    # standard input closes with the host, which ends an embedded Neovim.
    class Client
      # A value as it crosses the channel.
      alias Value = MessagePack::Type

      # A notification handler: the method name and its parameters.
      alias NotificationHandler = Proc(String, Array(MessagePack::Type), Nil)

      # A request handler: the method name and its parameters, returning the
      # result to send back; raising answers with the exception's message as
      # the error.
      alias RequestHandler = Proc(String, Array(MessagePack::Type), Value)

      # An exit handler: the exit code, `nil` when the process was killed by
      # a signal.
      alias ExitHandler = Proc(Int32?, Nil)

      # Bytes of Neovim's standard error kept by `#error_output` — its tail.
      ERROR_OUTPUT_CAP = 64 * 1024

      # The running Neovim process.
      getter process : Process

      # The exit code, once the process has ended (`nil` before, and when a
      # signal ended it).
      getter exit_code : Int32? = nil

      # Message types of msgpack-RPC.
      private REQUEST      = 0
      private RESPONSE     = 1
      private NOTIFICATION = 2

      # What the reader hands the dispatch fiber, in arrival order.
      private record Notification, method : String, params : Array(MessagePack::Type)
      private record IncomingRequest, id : Int64, method : String, params : Array(MessagePack::Type)
      private record Exited, code : Int32?
      private record Reply, error : Value, result : Value
      private alias Message = Notification | IncomingRequest | Exited

      @input : IO
      @next_id = 0_u32
      @pending = {} of UInt32 => Channel(Reply)
      @write_lock = Mutex.new
      @queue = Deque(Message).new
      @wake = Channel(Nil).new 1
      @reader_done = Channel(Nil).new
      @exited = Channel(Nil).new
      @gone = false
      @error_output = IO::Memory.new
      @notification_handlers = [] of NotificationHandler
      @exit_handlers = [] of ExitHandler
      @request_handler : RequestHandler? = nil
      @channel_id : Int64? = nil

      # The buffer in Neovim's window, as the `Handler`s sharing this client
      # last showed it.
      protected property shown_buffer : Int64? = nil

      # Held by a `Handler` while it sends Neovim a change and then keys
      # (`Handler#exclusive`).
      protected getter handler_lock = Mutex.new

      # Starts `nvim --embed` followed by *args* (`--clean`, `-u NONE`,
      # `--noplugin`, a file to edit, …). Without `--headless` among them,
      # Neovim answers requests at once but holds its startup (the user's
      # config, the files to edit) until a UI attaches (`nvim_ui_attach`);
      # with it, there is no UI to wait for.
      #
      # *executable* is a name looked up in `PATH`, or a path
      # (`Neovim.executable` by default); *env* and *chdir* are the process's
      # environment additions and working directory, as for `Process.new`.
      # Raises `Neovim::Error` when the executable is not found.
      def initialize(*, args : Enumerable(String) = [] of String, executable : String = Neovim.executable,
                     env : Process::Env = nil, chdir : String? = nil)
        path = Neovim.find_executable(executable) || raise Error.new "Neovim executable not found: #{executable}"
        @process = Process.new(path, ["--embed"] + args.to_a, env: env, chdir: chdir,
          input: :pipe, output: :pipe, error: :pipe)
        @input = @process.input
        spawn(name: "Neovim::Client reader") { read_loop @process.output }
        spawn(name: "Neovim::Client dispatcher") { dispatch_loop }
        spawn(name: "Neovim::Client stderr") { drain_error_output @process.error }
        spawn(name: "Neovim::Client waiter") { wait_for_exit }
      end

      # The process's ID.
      def pid : Int64
        @process.pid
      end

      # Whether the process is still running and the channel open.
      def running? : Bool
        !@gone
      end

      # The tail of what Neovim wrote to its standard error (at most
      # `ERROR_OUTPUT_CAP` bytes), for reporting why it failed to start or
      # ended.
      def error_output : String
        @error_output.to_s
      end

      # Calls the API function *method* with *params* and returns its result,
      # parking the calling fiber (never the scheduler) until Neovim answers.
      # Raises `Neovim::Error` with Neovim's message when it answers with an
      # error, and when the process has ended or ends before answering, or
      # when no answer has come within *timeout*.
      #
      # ```
      # nvim.request("nvim_eval", "1+2").as_i              # => 3
      # nvim.request("nvim_buf_get_lines", 0, 0, -1, true) # an array of lines
      # ```
      def request(method : String, *params, timeout : Time::Span? = nil) : MessagePack::Any
        request_with method, params, timeout
      end

      # `#request` with its parameters given as an array or tuple.
      def request_with(method : String, params : Array | Tuple, timeout : Time::Span? = nil) : MessagePack::Any
        raise Error.new "Neovim has exited" if @gone
        ch = Channel(Reply).new 1
        id = (@next_id &+= 1)
        @pending[id] = ch
        begin
          send_message do |pk|
            pk.write_array_start 4
            pk.write REQUEST
            pk.write id
            pk.write method
            write_params pk, params
          end
        rescue ex
          @pending.delete id
          raise ex
        end

        reply =
          if timeout
            select
            when r = ch.receive?
              r
            when timeout(timeout)
              @pending.delete id
              raise Error.new "Neovim did not answer #{method} within #{timeout}"
            end
          else
            ch.receive?
          end
        raise Error.new "Neovim exited before answering #{method}" unless reply

        raise error_from(reply.error) unless reply.error.nil?
        MessagePack::Any.new reply.result
      end

      # Calls the API function *method* with *params* without waiting for it
      # (msgpack-RPC notification): nothing comes back, and an error is only
      # reported by Neovim itself (an `nvim_error_event` notification).
      # Raises `Neovim::Error` when the process has ended.
      def notify(method : String, *params) : Nil
        notify_with method, params
      end

      # `#notify` with its parameters given as an array or tuple.
      def notify_with(method : String, params : Array | Tuple) : Nil
        raise Error.new "Neovim has exited" if @gone
        send_message do |pk|
          pk.write_array_start 3
          pk.write NOTIFICATION
          pk.write method
          write_params pk, params
        end
      end

      # Calls *block* with the method name and the parameters of every
      # notification Neovim sends, on the client's dispatch fiber, in order.
      # Returns the block, for `#off_notification`.
      #
      # ```
      # nvim.on_notification do |method, params|
      #   handle_redraw params if method == "redraw"
      # end
      # ```
      def on_notification(&block : String, Array(MessagePack::Type) ->) : NotificationHandler
        @notification_handlers << block
        block
      end

      # Removes a block `#on_notification` added.
      def off_notification(handler : NotificationHandler) : Nil
        @notification_handlers.delete handler
      end

      # Answers the requests Neovim sends the host (`rpcrequest()`): *block*
      # gets the method name and the parameters and returns the result, or
      # raises to answer with an error. Replaces any earlier block; without
      # one every request is answered with an error, so Neovim never waits on
      # a host that does not answer.
      def on_request(&block : String, Array(MessagePack::Type) -> Value) : Nil
        @request_handler = block
      end

      # Calls *block* with the exit code (`nil` for a signal) once the process
      # has ended, on the dispatch fiber, after every notification sent before
      # it. A block added after the end is called at once.
      def on_exit(&block : Int32? ->) : ExitHandler
        if @gone && @exited_dispatched
          block.call @exit_code
        else
          @exit_handlers << block
        end
        block
      end

      # Removes a block `#on_exit` added, so a holder that lets go of a shared
      # client (`Handler#detach`) leaves no block behind on it.
      def off_exit(handler : ExitHandler) : Nil
        @exit_handlers.delete handler
      end

      @exited_dispatched = false

      # This client's channel ID in Neovim — what `rpcnotify()` and
      # `rpcrequest()` take to reach the host, e.g. from an autocommand or a
      # user command. Asked once (`nvim_get_api_info`) and remembered.
      def channel_id : Int64
        @channel_id ||= request("nvim_get_api_info")[0].as_i64
      end

      # Ends Neovim: tells it `:qall!` (no question about unsaved changes)
      # and waits up to *grace* for it to exit; failing that closes its
      # standard input, on which an embedded Neovim quits in any case, then
      # terminates it, then kills it, waiting as long after each. Returns the
      # exit code (`nil` for a signal). Idempotent: called again, or after
      # Neovim quit on its own, it only returns the code.
      #
      # Neither step waits on the write lock: a Neovim that stopped reading
      # leaves a write parked on its full input holding it, and the quit is
      # sent from a fiber of its own while closing the input wakes that
      # write with an error.
      def close(grace : Time::Span = 2.seconds) : Int32?
        unless @gone
          spawn(name: "Neovim::Client quit") { notify_with "nvim_command", {"qall!"} rescue nil }
          unless exited_within? grace
            @input.close rescue nil
            unless exited_within? grace
              @process.terminate rescue nil
              unless exited_within? grace
                @process.signal Signal::KILL rescue nil
                exited_within? grace
              end
            end
          end
        end
        @exit_code
      end

      # Waits until the process has ended or *timeout* passed; returns
      # whether it ended.
      private def exited_within?(timeout : Time::Span) : Bool
        select
        when @exited.receive?
          true
        when timeout(timeout)
          @gone
        end
      end

      # Packs one message and writes it whole: the lock keeps two fibers'
      # messages from interleaving on the pipe when a write parks.
      private def send_message(& : MessagePack::Packer ->) : Nil
        @write_lock.synchronize do
          raise Error.new "Neovim has exited" if @gone
          begin
            yield MessagePack::Packer.new(@input)
            @input.flush
          rescue ex : IO::Error
            raise Error.new "Writing to Neovim failed: #{ex.message}"
          end
        end
      end

      private def write_params(pk : MessagePack::Packer, params : Array | Tuple) : Nil
        params.to_msgpack pk
      end

      private def error_from(error : Value) : Error
        if (a = error.as?(Array(MessagePack::Type))) && a.size >= 2
          Error.new a[1].to_s, a[0].as?(Int).try(&.to_i32)
        else
          Error.new error.to_s
        end
      end

      # Reads messages off Neovim's standard output until it closes: answers
      # resolve the request parked on them right here, everything else is
      # queued for the dispatch fiber (where a handler may make requests,
      # whose answers this fiber must stay free to read).
      private def read_loop(io : IO) : Nil
        unpacker = MessagePack::IOUnpacker.new io
        loop do
          msg = read_value(unpacker).as?(Array(MessagePack::Type))
          next unless msg && msg.size >= 3
          case msg[0].as?(Int).try(&.to_i)
          when RESPONSE
            next unless msg.size >= 4
            id = msg[1].as?(Int).try(&.to_u32!)
            if id && (ch = @pending.delete id)
              ch.send Reply.new(msg[2], msg[3])
            end
          when NOTIFICATION
            enqueue Notification.new(msg[1].to_s, msg[2].as?(Array(MessagePack::Type)) || [] of MessagePack::Type)
          when REQUEST
            next unless msg.size >= 4
            id = msg[1].as?(Int).try(&.to_i64) || next
            enqueue IncomingRequest.new(id, msg[2].to_s, msg[3].as?(Array(MessagePack::Type)) || [] of MessagePack::Type)
          end
        end
      rescue MessagePack::EofError | IO::Error
        # Neovim closed its end.
      ensure
        @reader_done.close
      end

      # One value off the stream, as `MessagePack::Unpacker#read` reads it,
      # except that the extension types Neovim sends its handles as are read
      # as the handle's number instead of raising.
      private def read_value(u : MessagePack::Unpacker) : Value
        case token = u.read_token
        when MessagePack::Token::NullT
          nil
        when MessagePack::Token::BoolT, MessagePack::Token::IntT, MessagePack::Token::FloatT,
             MessagePack::Token::StringT, MessagePack::Token::BytesT
          token.value
        when MessagePack::Token::ArrayT
          Array(MessagePack::Type).new(token.size) { read_value u }
        when MessagePack::Token::HashT
          h = Hash(MessagePack::Type, MessagePack::Type).new(initial_capacity: token.size)
          token.size.times { h[read_value u] = read_value u }
          h
        when MessagePack::Token::ExtT
          handle = MessagePack::IOUnpacker.new(token.bytes).read rescue nil
          handle.as?(Int).try(&.to_i64) || 0_i64
        end
      end

      private def enqueue(msg : Message) : Nil
        @queue << msg
        select
        when @wake.send(nil)
        else
        end
      end

      # Hands queued notifications and requests to the handlers, in order,
      # until the exit has been handed over.
      private def dispatch_loop : Nil
        loop do
          @wake.receive
          while msg = @queue.shift?
            case msg
            in Notification
              @notification_handlers.dup.each do |h|
                guard("notification #{msg.method}") { h.call msg.method, msg.params }
              end
            in IncomingRequest
              answer msg
            in Exited
              @exited_dispatched = true
              @exit_handlers.dup.each { |h| guard("exit") { h.call msg.code } }
              @exit_handlers.clear
              return
            end
          end
        end
      end

      # Runs a handler, logging what it raises rather than letting it end
      # the dispatch fiber, which would leave every later message unhandled.
      private def guard(what : String, &) : Nil
        yield
      rescue ex
        ::Log.error(exception: ex) { "Crysterm::Neovim::Client: #{what} handler raised" }
      end

      private def answer(req : IncomingRequest) : Nil
        error = nil.as(Value)
        result = nil.as(Value)
        if h = @request_handler
          begin
            result = h.call req.method, req.params
          rescue ex
            error = ex.message || ex.class.name
          end
        else
          error = "Crysterm::Neovim::Client: no handler for request #{req.method}"
        end
        send_message do |pk|
          pk.write_array_start 4
          pk.write RESPONSE
          pk.write req.id
          error.to_msgpack pk
          result.to_msgpack pk
        end
      rescue Error
        # Neovim went away before the answer could be written.
      end

      # Reaps the process, then — once its output is read to the end, so
      # every answer and notification it sent is in — fails the requests
      # still waiting and hands the exit to the dispatch fiber.
      private def wait_for_exit : Nil
        status = @process.wait
        @exit_code = status.normal_exit? ? status.exit_code : nil
        select
        when @reader_done.receive?
        when timeout(1.second)
        end
        @write_lock.synchronize do
          @gone = true
          @input.close rescue nil
        end
        @pending.each_value &.close
        @pending.clear
        enqueue Exited.new(@exit_code)
        @exited.close
      end

      private def drain_error_output(io : IO) : Nil
        buf = Bytes.new 4096
        while (n = io.read buf) > 0
          @error_output.write buf[0, n]
          if @error_output.size > ERROR_OUTPUT_CAP
            tail = @error_output.to_slice[-ERROR_OUTPUT_CAP..].dup
            @error_output = IO::Memory.new
            @error_output.write tail
          end
        end
      rescue IO::Error
      end
    end
  end
end
