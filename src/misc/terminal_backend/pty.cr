module Crysterm
  # Pseudo-terminal (PTY) support.
  #
  # SUPPORTING CODE — this is a self-contained helper with no dependency on the
  # rest of Crysterm and is a prime candidate for extraction into a standalone
  # `pty` shard (the way `tput`, `term_colors`, etc. already are). It is kept
  # here for now so the `Widget::Terminal` port is usable out of the box.
  #
  # It allocates a master/slave pseudo-terminal pair with `openpty(3)` and spawns
  # the child with Crystal's `Process`, wiring the slave to the child's
  # stdin/stdout/stderr. The master side is exposed as an ordinary
  # `IO::FileDescriptor`: read it for the child's output, write to it to deliver
  # input. `#resize` issues the `TIOCSWINSZ` ioctl so the child learns about
  # geometry changes.
  #
  # SAFETY: spawning goes through `Process.new`, which performs a fork+exec the
  # Crystal runtime is designed for, and reaps the child itself. We never call a
  # raw `fork`/`forkpty` (unsafe inside a GC'd, fibered runtime) and never signal
  # a raw PID — `#kill` only ever signals *this* `Process`, so it cannot affect
  # any other process on the machine.
  #
  # CONTROLLING TERMINAL: to get a controlling terminal (and therefore job
  # control, and no "cannot set terminal process group" warning) without a
  # pre-exec hook, the command is run through the `setsid(1)` helper — see
  # `#spawn_child`. That keeps everything on the safe `Process` path.
  class Pty
    # `openpty` lives in libutil; `ioctl` is already bound by Crystal's `LibC`.
    @[Link("util")]
    lib LibUtil
      # `struct winsize` from <termios.h>.
      struct Winsize
        ws_row : LibC::UShort
        ws_col : LibC::UShort
        ws_xpixel : LibC::UShort
        ws_ypixel : LibC::UShort
      end

      # `int openpty(int *amaster, int *aslave, char *name,
      #              const struct termios *termp, const struct winsize *winp);`
      fun openpty(amaster : LibC::Int*, aslave : LibC::Int*, name : LibC::Char*,
                  termp : Void*, winp : Winsize*) : LibC::Int
    end

    # `TIOCSWINSZ` request number (Linux, arch-independent for mainstream archs).
    TIOCSWINSZ = 0x5414_u64

    # The master side of the PTY. Read it for child output; write to it to send
    # input to the child. Crystal classifies a PTY master (a character device) as
    # non-blocking, so reads from a fiber yield through the event loop rather than
    # parking the whole (single) thread — which would otherwise starve the
    # screen's keyboard-input fiber.
    getter master : IO::FileDescriptor

    # The spawned child process. Signalling/reaping always go through this object,
    # so they target exactly this PID and nothing else.
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

      ws = LibUtil::Winsize.new
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

    # Spawns the child on the safe `Process` path. When the `setsid(1)` helper is
    # available it runs the command through `setsid -c`, which makes the child a
    # session leader with the slave PTY as its **controlling terminal** — so job
    # control works and an interactive shell no longer prints "cannot set
    # terminal process group / no job control".
    #
    # We deliberately do NOT pass `-w` (wait): `-w` would keep `setsid` blocked
    # on the child, so our own `#reap` (`Process#wait`) could hang forever if the
    # child ignored the hang-up. Without `-w`, `setsid` exec's the command
    # in place — so `@process` is the shell itself: directly signalable, reapable,
    # and with the slave as its controlling terminal. Closing the master then
    # delivers `SIGHUP` to it cleanly. (No bare `fork`/`forkpty` anywhere; if
    # `setsid` is missing we fall back to a plain spawn, which works minus job
    # control.)
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
      ws = LibUtil::Winsize.new
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

    # The child's exit status. Intended to be called once the master has reported
    # EOF (the child has closed the PTY, so it is exiting): `Process#wait` then
    # returns promptly with the status, cooperatively yielding the fiber rather
    # than busy-waiting. Returns `nil` if the status carries no exit code (e.g.
    # the child was terminated by a signal). The result is cached.
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
        # Child already gone / not signalable — nothing to do.
      end
      @master.close rescue nil
    end
  end
end
