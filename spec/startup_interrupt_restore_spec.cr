require "./spec_helper"

include Crysterm

# Regression: interrupting a program during the startup window — after
# `Window.new` has entered the alternate buffer and hidden the cursor (`#enter`,
# run from the constructor) but before any render/listen/draw — must still
# leave the terminal in a clean state.
#
# That window exists because until the input fiber establishes raw mode (in
# `#listen`, reached only from `#exec`), the tty is in cooked mode, so Ctrl+C is
# delivered as a real SIGINT. The SIGINT/TERM/QUIT traps in `crysterm.cr`
# (armed at module-load, before any terminal-mode change) route the signal
# through `exit`, running the `at_exit` handler:
#
#   exit -> at_exit -> Window#destroy -> #disconnect -> #restore_terminal -> #leave
#
# This spec drives `#destroy` directly on a headless screen (the signal path
# itself isn't portable to a unit spec), checking:
#   1. setup-then-teardown restores the terminal even when drawing never began;
#   2. teardown is idempotent (a second `#destroy` does nothing and never raises).
private def sir_screen(buf : IO) : Crysterm::Window
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: buf,
    error: IO::Memory.new,
    width: 80, height: 24)
end

describe "Window teardown during the startup window (before first draw)" do
  it "restores the terminal when destroyed before any draw/listen" do
    buf = IO::Memory.new
    s = sir_screen buf

    # The constructor ran `#enter`: alternate buffer on, hardware cursor hidden.
    enter = buf.to_s
    enter.should contain("\e[?1049h") # entered the alternate buffer
    enter.should contain("\e[?25l")   # cursor hidden
    s.tput.is_alt.should be_true

    # Simulate the early-Ctrl+C teardown path: no render, no listen, no draw,
    # just the `at_exit`-driven destroy.
    s.destroy

    restore = buf.to_s[enter.size..]
    restore.should contain("\e[?1049l") # left the alternate buffer (cleanup)
    restore.should contain("\e[?25h")   # cursor shown again
    s.tput.is_alt.should be_false
  end

  it "is idempotent: a second destroy emits nothing and does not raise" do
    buf = IO::Memory.new
    s = sir_screen buf

    s.destroy
    after_first = buf.to_s.size

    s.destroy # must be a no-op
    buf.to_s.size.should eq(after_first)
  end
end
