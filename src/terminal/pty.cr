module Crysterm
  # Pseudo-terminal (PTY) support. Self-contained: no dependency on the rest of
  # Crysterm.
  #
  # Allocates a master/slave PTY pair with `openpty(3)` and spawns the child
  # with Crystal's `Process`, wiring the slave to its stdin/stdout/stderr. The
  # master is exposed as an ordinary `IO::FileDescriptor`: read for output,
  # write to send input. `#resize` issues `TIOCSWINSZ` for geometry changes.
  #
  # SAFETY: spawning must stay on `Process.new` (fork+exec, reaped by Crystal).
  # Raw `fork`/`forkpty` is unsafe in a GC'd, fibered runtime, and nothing here
  # may signal a raw PID — `#kill` only signals *this* `Process`.
  class Pty
    # `openpty` lives in libutil and must be bound here; `ioctl` and
    # `LibC::Winsize` are already bound by Crystal's stdlib `LibC`.
    @[Link("util")]
    lib LibUtil
      # `int openpty(int *amaster, int *aslave, char *name,
      #              const struct termios *termp, const struct winsize *winp);`
      fun openpty(amaster : LibC::Int*, aslave : LibC::Int*, name : LibC::Char*,
                  termp : Void*, winp : LibC::Winsize*) : LibC::Int
    end

    # `TIOCSWINSZ` request number. Must stay platform-specific: BSD/macOS encode
    # it as `_IOW('t', 103, struct winsize)` (`0x80087467`), Linux as a flat
    # `0x5414`. Hardcoding the Linux value issues the wrong ioctl on macOS/BSD,
    # silently making `#resize` a no-op there.
    {% if flag?(:darwin) || flag?(:bsd) %}
      # BSD/macOS `_IOW('t', 103, struct winsize)`: IOC_OUT | (size << 16) |
      # (group << 8) | num. Size is derived from `sizeof(LibC::Winsize)` so the
      # request survives a struct-layout change; `0x80087467` for the usual
      # 8-byte winsize.
      TIOCSWINSZ = (0x80000000_u64 |
                    ((sizeof(LibC::Winsize).to_u64 & 0x1fff) << 16) |
                    ('t'.ord.to_u64 << 8) | 103_u64)
    {% elsif flag?(:solaris) %}
      TIOCSWINSZ = 0x5467_u64
    {% else %}
      TIOCSWINSZ = 0x5414_u64 # Linux (and the default for anything else)
    {% end %}

    # The master side of the PTY. Read for child output, write to send input.
    # Crystal treats a PTY master as non-blocking, so fiber reads yield through
    # the event loop rather than parking the thread and starving keyboard input.
    getter master : IO::FileDescriptor

    # The spawned child process. Signalling/reaping must go through this object,
    # so they target exactly this PID.
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

      # `IO::FileDescriptor.new` does not set `FD_CLOEXEC` on the fd it wraps
      # (it only queries/toggles the kernel flag) and `openpty(3)` doesn't set
      # it either, so without this every fork (this spawn, and any descendant
      # the child later forks) inherits a live copy of both ends of the pty.
      # The slave's copy is safe to mark CLOEXEC before spawning: `Process.new`
      # reaches the child's stdio via `dup2`, which always clears CLOEXEC on
      # the duplicate, so fds 0/1/2 in the child survive exec regardless — only
      # the extra, higher-numbered fd (this `slave` local, and the parent's
      # `@master`) gets closed at exec time.
      @master.close_on_exec = true
      slave.close_on_exec = true

      process = begin
        spawn_child command, args, slave, env, chdir
      rescue ex
        # Close both fds before propagating, else they leak until GC finalizes them.
        @master.close rescue nil
        slave.close rescue nil
        raise ex
      end
      @process = process

      # The child holds its own dup'd copies of the slave fds; the parent must
      # close the slave so the master reports EOF once the child exits.
      slave.close
    end

    # Spawns the child, through `setsid -c` when available so it becomes a session
    # leader with the slave PTY as its controlling terminal (job control works, and
    # an interactive shell doesn't print "cannot set terminal process group").
    # Falls back to a plain spawn, minus job control, if `setsid` is missing.
    #
    # Never pass `-w` (wait): `setsid` would stay blocked on the child, so `#reap`
    # could hang forever if the child ignored the hang-up. Without it `setsid`
    # execs in place, leaving `@process` as the shell itself — directly
    # signalable/reapable, and killed cleanly by SIGHUP when the master closes.
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
      if LibC.ioctl(@master.fd, TIOCSWINSZ, pointerof(ws)) != 0
        raise RuntimeError.from_errno("ioctl(TIOCSWINSZ)")
      end
    end

    # Writes input bytes to the child and flushes immediately (keystrokes must
    # not sit in a buffer).
    def write(data : Bytes | String) : Nil
      return if @closed
      @master.write data.to_slice
      @master.flush
    end

    # The child's exit status, cached. Call only once the master reports EOF, so
    # `Process#wait` returns promptly instead of parking the fiber indefinitely.
    # `nil` if there is no exit code (e.g. killed by signal).
    def reap : Int32?
      return @exit_code if @reaped
      @reaped = true
      @exit_code = (@process.wait.exit_code rescue nil)
    end

    # Hangs up the child (SIGHUP to *this* process only) and releases the
    # master fd, then escalates to SIGTERM and SIGKILL on its own fiber if the
    # child is still alive after *grace* — a child that ignores or traps HUP
    # (`nohup`, `trap '' HUP`, a daemon) would otherwise never exit, leaving
    # `#reap`'s `Process#wait` parked forever. Idempotent; every signal is
    # best-effort (a process that has already exited is skipped, and a race
    # losing to that check is swallowed).
    def kill(grace : Time::Span = 2.seconds) : Nil
      return if @closed
      @closed = true
      process = @process
      begin
        process.signal Signal::HUP unless process.terminated?
      rescue
      end
      spawn do
        sleep grace
        unless process.terminated?
          begin
            process.signal Signal::TERM
          rescue
          end
        end
        sleep grace
        unless process.terminated?
          begin
            process.signal Signal::KILL
          rescue
          end
        end
      end
      @master.close rescue nil
    end
  end
end
