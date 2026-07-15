require "./log"

module Crysterm
  class Widget
    # Streams a file descriptor / `IO` — or a spawned subprocess's output — into a
    # scrolling text box. This is crysterm's answer to notcurses' `ncfdplane`
    # (the `IO` form) and `ncsubproc` (the command form).
    #
    # **Text mode only.** Raw UTF-8 lines are appended and autoscrolled (via the
    # `Log` base); escape sequences are *not* interpreted — a `\e[31m` shows up as
    # literal bytes. For a program that paints with cursor/colour control (vim,
    # htop, a pager) use the full `Widget::Terminal` VT emulator instead. LogFd
    # is the cheap "just tail this fd into a box" primitive.
    #
    # ```
    # # Tail an existing IO (a pipe, socket, opened file, ...):
    # LogFd.new io: some_io, parent: window
    #
    # # Or spawn a command and stream its stdout+stderr (the `ncsubproc` case):
    # LogFd.new "journalctl", ["-f"], parent: window
    # ```
    #
    # Reading begins once the widget is attached to a window (`Event::Attach`), so
    # appended lines can be marshalled onto the render fiber. You can also drive it
    # yourself, headless, by calling `#feed` with bytes/strings.
    class LogFd < Log
      # The spawned child, when constructed from a command (the `ncsubproc` case);
      # `nil` when wrapping a caller-supplied `IO`. Signalling/reaping go through
      # this object.
      getter process : Process?

      getter? closed = false

      # A partial trailing line (and/or an incomplete final read) carried across
      # `#feed` calls so a line split at a chunk boundary isn't emitted early.
      # UTF-8 glyphs are never split by newline-based chunking — a continuation
      # byte (`0x80`–`0xBF`) can never equal `'\n'` (`0x0A`) — so splitting on the
      # newline byte never corrupts a multibyte character.
      @carry : Bytes = Bytes.new(0)

      @io : IO?
      @started = false

      # A single logical line is flushed unconditionally once its buffered bytes
      # exceed this, so a firehose that never emits a newline can't grow `@carry`
      # (and its per-chunk recopy) without bound.
      MAX_LINE_BYTES = 1 << 20

      # Wrap an existing readable `IO` (a pipe, socket, file, ...). The `IO` is
      # read on a background fiber once the widget is attached; on EOF the fiber
      # stops. The caller owns the `IO`'s lifetime beyond `#close`.
      def initialize(io : IO, **log)
        super **log
        @io = io
        wire
      end

      # Spawn *command* (with *args*) and stream its stdout **and** stderr into the
      # plane, merged into one pipe so diagnostics interleave with output like a
      # real terminal tail. stdin is closed.
      #
      # The child is spawned immediately (so a bad command raises here, not later)
      # but only drained once the widget is attached. `#close` / destroy terminate
      # and reap it.
      def initialize(command : String, args : Array(String) = [] of String,
                     env : Process::Env = nil, chdir : String? = nil, **log)
        super **log

        # One pipe fed by both stdout and stderr: the parent reads a single
        # stream, and closing our copy of the write end lets the reader see EOF
        # when the child exits. `IO.pipe` defaults to a non-blocking read end, so
        # the reader fiber yields through the event loop instead of parking the
        # thread and starving keyboard input.
        reader, writer = IO.pipe
        process = begin
          Process.new(command, args, env: env, chdir: chdir,
            input: Process::Redirect::Close, output: writer, error: writer)
        rescue ex
          reader.close rescue nil
          writer.close rescue nil
          raise ex
        end
        writer.close # the child holds its own dup'd copy

        @process = process
        @io = reader
        wire
      end

      private def wire : Nil
        on(::Crysterm::Event::Attach) { start }
        on(::Crysterm::Event::Destroy) { close }
        # A `parent:`/`window:` passed to the constructor already fired
        # `Event::Attach` during `super`, before the handler above existed, so
        # kick the reader off now if we're already attached. Later re-attaches go
        # through the handler (a no-op once `@started`).
        start if window?
      end

      # Splits *carry* + *chunk* on the newline byte into complete lines, stripping
      # a trailing `\r` (CRLF streams), and returns the extracted lines plus the
      # leftover partial line to carry into the next call. Pure and side-effect free.
      def self.extract_lines(carry : Bytes, chunk : Bytes) : {Array(String), Bytes}
        buf = Bytes.new(carry.size + chunk.size)
        carry.copy_to(buf) unless carry.empty?
        chunk.copy_to(buf[carry.size, chunk.size]) unless chunk.empty?

        lines = [] of String
        start = 0
        buf.each_with_index do |b, i|
          next unless b == 0x0A_u8 # '\n'
          stop = i
          stop -= 1 if stop > start && buf[stop - 1] == 0x0D_u8 # trailing '\r'
          lines << String.new(buf[start, stop - start])
          start = i + 1
        end

        rem = buf.size - start
        new_carry = Bytes.new(rem)
        buf[start, rem].copy_to(new_carry) if rem > 0
        {lines, new_carry}
      end

      # Feed a raw chunk (bytes or string) into the plane: split into complete
      # lines, append each, and carry any trailing partial line to the next call.
      # Public so you can drive the widget from your own source.
      def feed(data : Bytes | String) : Nil
        slice = data.is_a?(String) ? data.to_slice : data
        lines, @carry = LogFd.extract_lines(@carry, slice)
        lines.each { |l| add l }
        # A single line that never terminates must not grow the carry forever.
        flush_carry if @carry.size > MAX_LINE_BYTES
      end

      # Emit any buffered partial line as a final line (used on EOF and the
      # runaway-line cap). No-op when the carry is empty.
      def flush_carry : Nil
        return if @carry.empty?
        add String.new(@carry)
        @carry = Bytes.new(0)
      end

      # Starts the background reader. Idempotent (`Event::Attach` can re-fire on
      # re-attach) and a no-op once closed.
      private def start : Nil
        return if @started || @closed
        io = @io
        return unless io
        @started = true

        # A fresh buffer per read so the slice captured by the posted closure is
        # never overwritten by the next read before the render fiber consumes it.
        spawn do
          loop do
            buf = Bytes.new 8192
            n = io.read buf
            break if n <= 0
            data = buf[0, n]
            window?.try &.post { feed data }
          rescue
            break
          end
          window?.try &.post { flush_carry }
          reap
        end
      end

      # Reaps the child (if any) after EOF and surfaces its exit status. Runs on
      # the reader fiber, so `Process#wait` yields rather than blocking the loop.
      private def reap : Nil
        if p = @process
          code = p.wait.exit_code rescue nil
          emit ::Crysterm::Event::Exit, code
        end
      end

      # Stops streaming: closes our read end (unblocking the reader → EOF path)
      # and terminates the child. Idempotent; wired to `Event::Destroy`.
      def close : Nil
        return if @closed
        @closed = true
        @process.try { |p| p.terminate rescue nil }
        @io.try &.close rescue nil
        # If the reader never started, nothing else will reap the child.
        unless @started
          @process.try { |p| p.wait rescue nil }
        end
      end
    end
  end
end
