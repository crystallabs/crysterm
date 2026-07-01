module Crysterm
  # Pseudo-terminal (PTY) support.
  #
  # SUPPORTING CODE — self-contained, no dependency on the rest of Crysterm; a
  # candidate for extraction into a standalone `pty` shard (like `tput`,
  # `term_colors`). Kept here for now so `Widget::Terminal` is usable out of
  # the box.
  #
  # Allocates a master/slave PTY pair with `openpty(3)` and spawns the child
  # with Crystal's `Process`, wiring the slave to its stdin/stdout/stderr. The
  # master is exposed as an ordinary `IO::FileDescriptor`: read for output,
  # write to send input. `#resize` issues `TIOCSWINSZ` for geometry changes.
  #
  # SAFETY: spawning goes through `Process.new` (fork+exec, reaped by Crystal).
  # No raw `fork`/`forkpty` (unsafe in a GC'd, fibered runtime) and no signaling
  # a raw PID — `#kill` only signals *this* `Process`.
  #
  # CONTROLLING TERMINAL: to get one (job control, no "cannot set terminal
  # process group" warning) without a pre-exec hook, the command runs through
  # the `setsid(1)` helper — see `#spawn_child`.
  class Pty
    # `openpty` lives in libutil; `ioctl` and `struct winsize` (`LibC::Winsize`)
    # are already bound by the term-window shard — reused here for both calls.
    @[Link("util")]
    lib LibUtil
      # `int openpty(int *amaster, int *aslave, char *name,
      #              const struct termios *termp, const struct winsize *winp);`
      fun openpty(amaster : LibC::Int*, aslave : LibC::Int*, name : LibC::Char*,
                  termp : Void*, winp : LibC::Winsize*) : LibC::Int
    end

    # `TIOCSWINSZ` request number — write-side companion of the term-window
    # shard's `LibC::TIOCGWINSZ`, platform-specific for the same reason: BSD/macOS
    # `_IOW('t', 103, struct winsize)` encoding (`0x80087467`) differs from
    # Linux's flat `0x5414`. A hardcoded Linux value would silently issue the
    # wrong ioctl on macOS/BSD, making `#resize` a no-op there.
    {% if flag?(:darwin) || flag?(:bsd) %}
      TIOCSWINSZ = 0x80087467_u64
    {% elsif flag?(:solaris) %}
      TIOCSWINSZ = 0x5467_u64
    {% else %}
      TIOCSWINSZ = 0x5414_u64 # Linux (and the default for anything else)
    {% end %}

    # The master side of the PTY. Read for child output, write to send input.
    # Crystal treats a PTY master as non-blocking, so fiber reads yield through
    # the event loop instead of parking the thread and starving the window's
    # keyboard-input fiber.
    getter master : IO::FileDescriptor

    # The spawned child process. Signalling/reaping always go through this
    # object, targeting exactly this PID.
    getter process : Process

    getter? closed = false
    @exit_code : Int32? = nil
    @reaped = false

    # Spawns `command` (with `args`) attached to a fresh PTY sized `cols`x`rows`.
    def initialize(command : String, args : Array(String) = [] of String,
                   cols : Int32 = 80, rows : Int32 = 24,
                   env : Process::Env = nil, chdir : String? = nil)
      master_fd = uninitialized LibC::Int
      slave_fd = uninitialized LibC::Int

      ws = LibC::Winsize.new
      ws.ws_row = rows.to_u16
      ws.ws_col = cols.to_u16

      if LibUtil.openpty(pointerof(master_fd), pointerof(slave_fd),
           Pointer(LibC::Char).null, Pointer(Void).null, pointerof(ws)) != 0
        raise RuntimeError.from_errno("openpty")
      end

      @master = IO::FileDescriptor.new master_fd
      slave = IO::FileDescriptor.new slave_fd

      @process = spawn_child command, args, slave, env, chdir

      # The child holds its own dup'd copies of the slave fds; the parent must
      # close the slave so the master reports EOF once the child exits.
      slave.close
    end

    # Spawns the child on the safe `Process` path. When `setsid(1)` is available
    # it runs the command through `setsid -c`, making the child a session leader
    # with the slave PTY as its controlling terminal, so job control works and
    # an interactive shell doesn't print "cannot set terminal process group".
    #
    # Deliberately no `-w` (wait): that would keep `setsid` blocked on the
    # child, so `#reap` (`Process#wait`) could hang forever if the child ignored
    # the hang-up. Without `-w`, `setsid` execs the command in place, so
    # `@process` is the shell itself: directly signalable/reapable, with the
    # slave as its controlling terminal, so closing the master delivers SIGHUP
    # cleanly. Falls back to a plain spawn (minus job control) if `setsid` is
    # missing.
    private def spawn_child(command, args, slave, env, chdir) : Process
      base = {input: slave, output: slave, error: slave, env: env, chdir: chdir}
      if Process.find_executable("setsid")
        Process.new("setsid", ["-c", command] + args, **base)
      else
        Process.new(command, args, **base)
      end
    end

    # Tells the kernel (and thus the child) about a new terminal geometry.
    def resize(cols : Int32, rows : Int32) : Nil
      return if @closed
      ws = LibC::Winsize.new
      ws.ws_row = rows.to_u16
      ws.ws_col = cols.to_u16
      # `ioctl` is already declared (variadically) by Crystal's `LibC`.
      LibC.ioctl(@master.fd, TIOCSWINSZ, pointerof(ws))
    end

    # Writes input bytes to the child and flushes immediately (keystrokes must
    # not sit in a buffer).
    def write(data : Bytes | String) : Nil
      return if @closed
      @master.write data.to_slice
      @master.flush
    end

    # The child's exit status. Call once the master reports EOF (child closing
    # the PTY), so `Process#wait` returns promptly, yielding the fiber rather
    # than busy-waiting. Returns `nil` if there's no exit code (e.g. killed by
    # signal). Result is cached.
    def reap : Int32?
      return @exit_code if @reaped
      @reaped = true
      @exit_code = (@process.wait.exit_code rescue nil)
    end

    # Hangs up the child (SIGHUP to *this* process only) and releases the master
    # fd. Idempotent. Signals nothing if the child has already exited.
    def kill : Nil
      return if @closed
      @closed = true
      begin
        @process.signal Signal::HUP unless @process.terminated?
      rescue
        # Child already gone / not signalable.
      end
      @master.close rescue nil
    end
  end
end
