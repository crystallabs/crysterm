module Crysterm
  # Pseudo-terminal (PTY) support.
  #
  # SUPPORTING CODE — this is a self-contained helper with no dependency on the
  # rest of Crysterm and is a prime candidate for extraction into a standalone
  # `pty` shard (the way `tput`, `term_colors`, etc. already are). It is kept
  # here for now so the `Widget::Terminal` port is usable out of the box.
  #
  # It uses `forkpty(3)` to allocate a master/slave pseudo-terminal pair and
  # fork a child that is given the slave as its **controlling terminal** (via the
  # `login_tty(3)` that `forkpty` performs: `setsid(2)` + `TIOCSCTTY` + wiring the
  # slave to stdin/stdout/stderr). That is what makes job control work inside the
  # child (Ctrl-C/Ctrl-Z, foreground process groups) — a plain
  # `Process`-with-pipes spawn cannot do it, which is why an interactive `bash`
  # there printed "cannot set terminal process group / no job control".
  #
  # The master side is exposed as an ordinary `IO::FileDescriptor`: read it for
  # the child's output, write to it to deliver input. `#resize` issues the
  # `TIOCSWINSZ` ioctl so the child learns about geometry changes.
  #
  # Why `forkpty` and not Crystal's `Process`: `Process` offers no pre-exec hook,
  # so the controlling-tty setup (which must run in the child between fork and
  # exec) is impossible through it. We therefore fork ourselves. The child path
  # is careful to call **only** libc functions and never to allocate or touch the
  # Crystal runtime/GC before `exec` (the standard fork-then-exec discipline);
  # all the `argv`/`envp` C arrays are built in the parent beforehand.
  class Pty
    # `forkpty` lives in libutil; libc (always linked) provides the rest, which
    # Crystal already binds on `LibC` (`execvp`, `execvpe`, `_exit`, `chdir`,
    # `kill`, `waitpid`, `ioctl`) — we reuse those rather than redeclaring them
    # (redeclaring a libc fun with a differing signature is a compile error).
    @[Link("util")]
    lib LibPty
      # `struct winsize` from <termios.h>.
      struct Winsize
        ws_row : LibC::UShort
        ws_col : LibC::UShort
        ws_xpixel : LibC::UShort
        ws_ypixel : LibC::UShort
      end

      # `pid_t forkpty(int *amaster, char *name,
      #                const struct termios *termp, const struct winsize *winp);`
      fun forkpty(amaster : LibC::Int*, name : LibC::Char*,
                  termp : Void*, winp : Winsize*) : LibC::PidT
    end

    # `TIOCSWINSZ` request number (Linux, arch-independent for mainstream archs).
    TIOCSWINSZ = 0x5414_u64

    # The master side of the PTY. Read it for child output; write to it to send
    # input to the child. Integrates with Crystal's event loop, so reads from a
    # fiber cooperatively yield rather than blocking the whole program.
    getter master : IO::FileDescriptor

    # PID of the spawned child.
    getter pid : LibC::PidT

    # Child exit status (`WEXITSTATUS`), available once the child has been
    # reaped (see `#reap`); `nil` until then.
    getter exit_code : Int32? = nil

    getter? closed = false

    # Retained so the GC does not free the backing buffers whose raw pointers we
    # handed to `execvp`/`execvpe`.
    @command : String
    @args : Array(String)
    @env_strings : Array(String)? = nil
    @reaped = false

    # Spawns `command` (with `args`) attached to a fresh PTY sized `cols`x`rows`.
    # `env`, when given, fully replaces the child environment with the current
    # one merged with the overrides (a `nil` value removes a variable).
    def initialize(@command : String, @args : Array(String) = [] of String,
                   cols : Int32 = 80, rows : Int32 = 24,
                   env : Process::Env = nil, chdir : String? = nil)
      # Build the C arrays in the PARENT — the child must not allocate.
      argv = build_argv
      envp = env ? build_envp(env) : Pointer(LibC::Char*).null
      chdir_ptr = chdir ? chdir.to_unsafe : Pointer(LibC::Char).null

      ws = LibPty::Winsize.new
      ws.ws_row = rows.to_u16
      ws.ws_col = cols.to_u16

      master_fd = uninitialized LibC::Int
      pid = LibPty.forkpty(pointerof(master_fd), Pointer(LibC::Char).null,
        Pointer(Void).null, pointerof(ws))

      if pid < 0
        raise RuntimeError.from_errno("forkpty")
      elsif pid == 0
        # ── CHILD ──────────────────────────────────────────────────────────
        # The controlling terminal is already set up by forkpty/login_tty. Only
        # async-signal-safe libc calls from here on; never return.
        LibC.chdir(chdir_ptr) unless chdir_ptr.null?
        if envp.null?
          LibC.execvp(@command.to_unsafe, argv)
        else
          LibC.execvpe(@command.to_unsafe, argv, envp)
        end
        LibC._exit(127) # only reached if exec failed
      end

      # ── PARENT ────────────────────────────────────────────────────────────
      # NOTE: the reader fiber must never park the whole thread on a blocking
      # `read` — Crystal fibers are cooperatively scheduled on one thread, so a
      # blocking master read would starve the screen's keyboard-input fiber and
      # the terminal would render the child's output but accept no typing.
      # Crystal classifies a PTY master (a character device) as non-blocking by
      # default, so `read` yields through the event loop and the scheduler keeps
      # running — exactly what we need. (Were that ever not the case, force it
      # with `IO::FileDescriptor.set_blocking(master_fd, false)` before wrapping.)
      @pid = pid
      @master = IO::FileDescriptor.new(master_fd)
    end

    # NUL-terminated `argv` = [command, *args, NULL].
    private def build_argv : Pointer(LibC::Char*)
      ptr = Pointer(LibC::Char*).malloc(@args.size + 2)
      ptr[0] = @command.to_unsafe
      @args.each_with_index { |a, i| ptr[i + 1] = a.to_unsafe }
      ptr[@args.size + 1] = Pointer(LibC::Char).null
      ptr
    end

    # NUL-terminated `envp` from the current environment plus overrides.
    private def build_envp(env : Process::Env) : Pointer(LibC::Char*)
      merged = {} of String => String
      ENV.each { |k, v| merged[k] = v }
      env.each { |k, v| v.nil? ? merged.delete(k) : (merged[k] = v) }

      strings = merged.map { |k, v| "#{k}=#{v}" }
      @env_strings = strings # keep alive for the lifetime of the spawn
      ptr = Pointer(LibC::Char*).malloc(strings.size + 1)
      strings.each_with_index { |s, i| ptr[i] = s.to_unsafe }
      ptr[strings.size] = Pointer(LibC::Char).null
      ptr
    end

    # Tells the kernel (and thus the child) about a new terminal geometry.
    def resize(cols : Int32, rows : Int32) : Nil
      return if @closed
      ws = LibPty::Winsize.new
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

    # Reaps the child once it has exited and records `#exit_code`. Intended to be
    # called after the master reports EOF (the child is gone, so `waitpid`
    # returns promptly). Returns the exit code, or `nil` if not yet exited.
    def reap : Int32?
      return @exit_code if @reaped
      status = 0
      r = LibC.waitpid(@pid, pointerof(status), 0)
      if r == @pid
        @reaped = true
        @exit_code = (status & 0xff00) >> 8 # WEXITSTATUS
      end
      @exit_code
    end

    # Terminates the child (SIGHUP) and releases the master fd. Idempotent.
    def kill : Nil
      return if @closed
      @closed = true
      LibC.kill(@pid, Signal::HUP.value) unless @reaped
      @master.close rescue nil
      reap rescue nil
    end
  end
end
