require "./spec_helper"

include Crysterm

# Regression coverage for the per-frame cursor save/hide/restore/show burst in
# `Window#draw` (`window_drawing.cr`).
#
# While a frame is being written (many cell runs, each prefixed by a `cup`), the
# real terminal cursor must be hidden so it doesn't streak across the screen,
# then restored afterward. That burst must drive the HARDWARE cursor directly
# (`tput.hide_cursor`/`tput.show_cursor`). The bug: it used the screen-level
# `Window#hide_cursor`/`#show_cursor`, which dispatch on the *active* cursor —
# when that cursor is artificial they take the artificial branch, emitting no
# hide escape (so the real cursor still streaks) and calling `render_if_active`
# (scheduling a redundant render from inside `draw`).
private def hw_hide_screen(output = IO::Memory.new, width = 10, height = 4)
  Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
end

private def prime(s)
  s.alloc
  s.lines.size.times { |y| s.lines[y].size.times { |x| s.lines[y][x].char = '.' } }
  s.lines.each &.dirty=(true)
end

describe "Window#draw hardware cursor hide during the frame" do
  it "hides the hardware cursor even when the active cursor is artificial" do
    # Hardware-cursor baseline: with the hardware cursor shown, the draw burst
    # emits the terminal's hide-cursor escape. Capture it so the assertion below
    # is validated against this terminal's actual sequence rather than a guess.
    base_out = IO::Memory.new
    sb = hw_hide_screen base_out
    prime sb
    sb.tput.show_cursor # hardware cursor visible -> the burst must hide it
    base_out.clear
    sb.draw
    base_out.to_s.includes?("\e[?25l").should be_true

    # Now an artificial active cursor, hardware cursor still shown. The burst must
    # STILL emit the hardware hide escape (so the real cursor doesn't streak), and
    # must not flip the artificial cursor's own hidden state as a side effect.
    art_out = IO::Memory.new
    s = hw_hide_screen art_out
    prime s
    s.cursor.artificial = true
    s.cursor._hidden = false
    s.cursor._state = 1
    s.cursor.shape = Tput::CursorShape::Block
    s.tput.show_cursor
    art_out.clear

    s.draw

    # The hardware hide escape is present (was absent before the fix, because
    # the artificial branch of Window#hide_cursor emitted nothing).
    art_out.to_s.includes?("\e[?25l").should be_true
    # The artificial cursor's own visibility was untouched by the burst.
    s.cursor._hidden.should be_false
  end
end
