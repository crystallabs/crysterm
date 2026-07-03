require "socket"
require "./launchers"

module Crysterm
  module Terminal
    # A spawned terminal-emulator window and everything needed to drive and tear
    # it down. Built by `Terminal.spawn_window`; held by the `Window` bound to
    # the window (see `Window#connect` / `Window#adopt_window`).
    class Window
      # The backing process (for most backends this is the window; for the
      # gnome-terminal server, or D-Bus backends, it is a transient launcher —
      # see the LAUNCHERS notes).
      getter process : Process
      # The rendezvous connection to the in-window helper. Carries the initial
      # TTY report and subsequent `WINCH` notifications; its EOF means the window
      # closed.
      getter socket : UNIXSocket
      # Filesystem path of the rendezvous socket (unlinked on close).
      getter path : String
      # Device path of the window's TTY (e.g. `/dev/pts/7`).
      getter tty : String
      # Read/write file descriptors on the window's TTY — two separate handles,
      # mirroring STDIN/STDOUT (see `examples/multiple-terminals.cr`).
      getter input : IO::FileDescriptor
      getter output : IO::FileDescriptor

      @closed = false

      def initialize(@process, @socket, @path, @tty, @input, @output)
      end

      # Closes the window and releases all resources. Idempotent. Closing the
      # rendezvous socket makes the in-window helper exit, which tells the
      # emulator to close the window; killing the process is a fallback.
      def close : Nil
        return if @closed
        @closed = true
        @socket.close rescue nil
        @input.close rescue nil
        @output.close rescue nil
        Terminal.terminate_and_reap(@process)
        File.delete(@path) rescue nil
      end
    end

    # Monotonic-ish unique suffix for rendezvous paths without relying on
    # `Time`/`Random` (kept simple and collision-free within a process).
    @@counter = 0

    # How long to wait for the spawned window's helper to phone home.
    HANDSHAKE_TIMEOUT = 15.seconds

    # Best-effort terminate *process*, then reap it so it doesn't linger as a
    # zombie. Non-blocking: the wait happens on its own fiber.
    def self.terminate_and_reap(process : Process) : Nil
      process.terminate rescue nil
      spawn { process.wait rescue nil }
    end

    # Spawns a terminal window/pane/session via *launcher*, waits for the
    # in-window helper to report its TTY, opens that TTY, and returns a `Window`.
    # Raises if no backend is available, the binary can't be found, or the helper
    # does not connect in time.
    def self.spawn_window(*, launcher : Launcher | String | Nil = nil,
                          cols : Int32 = 80, rows : Int32 = 24,
                          title : String? = nil,
                          env : Process::Env = nil) : Window
      backend = resolve_launcher(launcher)
      raise "No terminal backend found (tried $TERMINAL and: #{LAUNCHERS.map(&.name).join(", ")})" unless backend

      exe = Process.executable_path
      raise "Cannot determine own executable path to launch the window helper" unless exe

      @@counter += 1
      dir = Crysterm::Config.environment_xdg_runtime_dir || Dir.tempdir
      path = File.join(dir, "crysterm-win-#{Process.pid}-#{@@counter}.sock")
      File.delete(path) rescue nil
      server = UNIXServer.new(path)

      # Tracks whether we hand the socket file to a live `Window` (which unlinks
      # it on close); on every failure path the `ensure` deletes it so a failed
      # spawn doesn't leak a dead `.sock` in `$XDG_RUNTIME_DIR`/tmp.
      success = false
      begin
        # Inline the handshake env var (and any user env) into the command, so it
        # reaches the helper even through a multiplexer server that doesn't
        # inherit our process environment.
        inner = ["env", "CRYSTERM_WINDOW_HELPER=#{path}"]
        env.try &.each { |k, v| inner << "#{k}=#{v}" if v }
        inner << exe

        process = backend.launch(inner, cols, rows, title)

        socket = accept_with_timeout(server)
        unless socket
          terminate_and_reap(process)
          raise "Timed out waiting for the #{backend.name} window to start"
        end

        # Bound the wait for the TTY report too, so a helper that connects but
        # never reports can't hang us forever. Cleared once the report arrives.
        socket.read_timeout = HANDSHAKE_TIMEOUT
        line = begin
          socket.gets
        rescue IO::TimeoutError
          nil
        end
        socket.read_timeout = nil

        unless line && line.starts_with?("TTY ")
          socket.close rescue nil
          terminate_and_reap(process)
          raise "Window helper did not report its TTY (got: #{line.inspect})"
        end
        tty = line[4..].strip

        begin
          input = File.open(tty, "r")
          output = File.open(tty, "w")
        rescue ex
          input.try &.close rescue nil
          socket.close rescue nil
          terminate_and_reap(process)
          raise "Could not open window TTY #{tty}: #{ex.message}"
        end
        win = Window.new(process, socket, path, tty, input, output)
        success = true # the Window now owns the socket file; leave it for #close
        win
      ensure
        server.close rescue nil
        # On any failure path the socket file is ours to clean up (the success
        # path leaves it for `Window#close`, which unlinks it).
        File.delete(path) rescue nil unless success
      end
    end

    # Accepts a single connection on *server*, returning `nil` if none arrives
    # within `HANDSHAKE_TIMEOUT`. Runs the blocking `accept` on its own fiber so
    # the wait can time out.
    private def self.accept_with_timeout(server : UNIXServer) : UNIXSocket?
      ch = Channel(UNIXSocket?).new(1)
      spawn do
        sock = server.accept?
        ch.send sock
      rescue
        ch.send nil
      end
      select
      when sock = ch.receive
        sock
      when timeout(HANDSHAKE_TIMEOUT)
        # The accept fiber may still be blocked in `accept?`; if it later
        # completes (or is unblocked by `spawn_window`'s `server.close`), drain
        # whatever it sends into this capacity-1 channel and close any late
        # socket so it doesn't leak its fd for the process lifetime.
        spawn { ch.receive?.try &.close }
        nil
      end
    end

    # If this process was launched as an in-window helper (env var set by
    # `spawn_window`), run the helper loop and exit — never returning to the
    # caller. Invoked once, very early, from `crysterm.cr`. A no-op otherwise.
    def self.run_helper_if_requested : Nil
      path = Crysterm::Config.terminal_window_helper
      return unless path
      run_helper(path)
      exit 0
    end

    # The in-window helper: reports this window's TTY back to the parent over
    # the rendezvous socket, forwards SIGWINCH as resize notifications, then
    # parks until the parent closes the socket (or sends "QUIT"), at which
    # point it exits, closing the window. Never reads or alters its stdin,
    # leaving the parent sole owner of the terminal's input/mode (documented
    # in `examples/multiple-terminals.cr` as `exec sleep infinity`).
    def self.run_helper(path : String) : Nil
      socket = UNIXSocket.new(path)
      tty = (File.readlink("/proc/self/fd/0") rescue nil)
      tty ||= (`tty`.strip rescue "")
      socket.puts "TTY #{tty}"
      socket.flush

      Signal::WINCH.trap do
        begin
          socket.puts "WINCH"
          socket.flush
        rescue
        end
      end

      # Park: block until the parent closes the connection (gets => nil) or asks
      # us to quit.
      while line = (socket.gets rescue nil)
        break if line.strip == "QUIT"
      end
    rescue
      # Any failure: fall through and let the process exit (closing the window).
    end
  end
end
