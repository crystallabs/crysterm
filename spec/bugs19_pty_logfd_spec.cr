require "./spec_helper"

# Regression specs for three PTY/LogFd process-lifecycle fixes:
#
# * `Pty`'s master (and slave) fds now carry `FD_CLOEXEC`, so they don't leak
#   into every child spawned through the PTY (or any descendant it forks).
# * `Pty#kill` escalates SIGHUP -> SIGTERM -> SIGKILL (bounded grace periods,
#   on its own fiber) instead of sending a single SIGHUP and leaving a child
#   that ignores it to run forever with the reader fiber parked in `#reap`.
# * `Widget::LogFd` only closes the `IO` it spawned itself (the command form);
#   the caller-`IO` form leaves the caller's `IO` open. `#close` also never
#   waits synchronously for the child to exit.
#
# These touch real child processes (no way to fake `FD_CLOEXEC` or signal
# escalation), but every wait here is bounded: no test blocks on a real tty
# or parks past a `select`/`timeout`, so nothing can stall the suite the way
# a pty-probe read could.

# Spec-only reacher: `LogFd` keeps the stream it reads private (`@io`), so the
# ownership contract ("closes the pipe it spawned, leaves a caller's `IO`
# alone") is read here instead of widening the production surface.
class Crysterm::Widget::LogFd
  # :nodoc:
  def spec_io_closed? : Bool
    !!@io.try(&.closed?)
  end
end

describe Crysterm::Pty do
  describe "close-on-exec (#24)" do
    it "marks the master fd close-on-exec so children don't inherit it" do
      pty = Crysterm::Pty.new("sleep", ["1"])
      begin
        pty.master.close_on_exec?.should be_true
      ensure
        pty.kill
      end
    end
  end

  describe "#kill escalation (#25)" do
    it "escalates to SIGTERM (and would to SIGKILL) when the child ignores SIGHUP" do
      # `trap '' HUP` makes the shell (and thus this session leader — `Pty`
      # spawns via `setsid -c`, execing in place) immune to the initial
      # SIGHUP. It does not trap SIGTERM, so the escalation's second signal
      # is what actually ends it.
      pty = Crysterm::Pty.new("sh", ["-c", "trap '' HUP; sleep 30"])
      pty.kill(5.milliseconds)

      done = Channel(Int32?).new(1)
      spawn { done.send pty.reap }

      select
      when code = done.receive
        # A signal death (not a normal exit) reports no exit code.
        code.nil?.should be_true
      when timeout(2.seconds)
        fail "Pty#kill did not escalate past the ignored SIGHUP within 2s"
      end
    end
  end
end

describe Crysterm::Widget::LogFd do
  describe "IO ownership (#28)" do
    it "leaves a caller-supplied IO open after #close" do
      # A headless window created first becomes the most-recent instance, so
      # the global-window fallback (`determine_window` → `Window.global`)
      # attaches this parentless widget to it rather than to a stale window
      # left behind by an earlier spec.
      win = headless_screen(80, 24, default_quit_keys: true)
      io = IO::Memory.new("")
      fd = Crysterm::Widget::LogFd.new(io: io, top: 0, left: 0, width: 40, height: 10)
      fd.close
      io.closed?.should be_false
    ensure
      win.try &.destroy
    end

    it "closes the pipe it owns for the spawned-command form" do
      win = headless_screen(80, 24, default_quit_keys: true)
      fd = Crysterm::Widget::LogFd.new("true", top: 0, left: 0, width: 40, height: 10)
      fd.spec_io_closed?.should be_false
      fd.close
      fd.spec_io_closed?.should be_true
    ensure
      win.try &.destroy
    end
  end

  describe "#close never blocks (#25)" do
    it "returns promptly even when the spawned child ignores SIGTERM" do
      # A standalone widget (no parent/window given) still resolves to the
      # global window and starts its reader eagerly (see `LogFd#wire`), so
      # this exercises the general "close must not block its caller" property
      # rather than specifically the `unless @started` fallback path.
      win = headless_screen(80, 24, default_quit_keys: true)
      fd = Crysterm::Widget::LogFd.new("sh", ["-c", "trap '' TERM; sleep 30"],
        top: 0, left: 0, width: 40, height: 10)
      process = fd.process.not_nil!

      done = Channel(Nil).new(1)
      spawn do
        fd.close
        done.send nil
      end

      select
      when done.receive
        # #close returned promptly instead of blocking the caller on
        # Process#wait for a child that ignores SIGTERM.
      when timeout(1.second)
        fail "LogFd#close blocked waiting on a child that ignores SIGTERM"
      end
    ensure
      process.try &.signal(Signal::KILL) rescue nil
      win.try &.destroy
    end
  end
end
