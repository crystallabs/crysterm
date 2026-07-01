require "./spec_helper"

include Crysterm

# Regression: clearing a hardware cursor color with `Window#cursor_color nil`
# must restore the terminal's default (OSC 112). It used to be a silent no-op —
# the `try`-guarded emission did nothing when `style.fg` was nil — leaving no way
# to reset the hardware cursor once a color was set. See
# `src/window_cursor.cr#cursor_color`.

describe "Window#cursor_color clearing (hardware path)" do
  it "emits the OSC 112 reset when the color is cleared with nil" do
    io = IO::Memory.new
    screen = Crysterm::Window.new(
      input: IO::Memory.new,
      output: io,
      error: IO::Memory.new)

    # Force determinism regardless of $TERM: pretend the terminal supports
    # hardware cursor recoloring.
    screen.tput.features.cursor_color = true
    screen.cursor.artificial = false

    # Set a concrete color (hardware path emits OSC 12, not OSC 112).
    screen.cursor_color "red"
    screen.cursor.style.fg.should eq Crysterm::Colors.convert("red")

    # Clearing must emit an OSC 112 reset, not nothing.
    mark = io.size
    screen.cursor_color nil
    screen.cursor.style.fg.should be_nil

    tail = String.new(io.to_slice[mark...io.size])
    tail.should contain("\e]112")
  end
end
