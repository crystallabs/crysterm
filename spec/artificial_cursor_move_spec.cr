require "./spec_helper"

include Crysterm

# Regression coverage for the artificial cursor in `Window#draw`
# (`screen_drawing.cr`).
#
# `draw` only scans a row when it is dirty or currently holds the cursor. The
# artificial cursor is composited into the cell at `(tput.cursor.x, cursor.y)`
# and written back into `@olines` (so the cursor glyph mirrors the terminal).
# When the cursor then moves to ANOTHER row without that old row's buffer
# content changing, the old row is not otherwise dirty — so without explicitly
# repairing it the cursor glyph stranded in `@olines` is never diffed away and a
# ghost cursor lingers on screen.
private def cursor_screen(output = IO::Memory.new, width = 10, height = 4)
  Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
end

describe "Window#draw artificial cursor movement" do
  it "erases the artificial cursor from the row it leaves" do
    s = cursor_screen
    s.alloc

    # Some stable content; prime @olines so it mirrors @lines (no cursor yet —
    # the default cursor is hardware, so nothing artificial is painted).
    s.lines.size.times { |y| s.lines[y].size.times { |x| s.lines[y][x].char = '.' } }
    s.lines.each &.dirty=(true)
    s.draw

    # Switch to a visible artificial block cursor and place it at (x1, y1).
    s.cursor.artificial = true
    s.cursor._hidden = false
    s.cursor._state = 1
    s.cursor.shape = Tput::CursorShape::Block

    x1, y1 = 3, 1
    s.tput.cursor.x = x1
    s.tput.cursor.y = y1
    s.draw

    # The cursor cell now carries REVERSE in @olines, while the underlying
    # content cell does not — i.e. the artificial cursor was painted there.
    (Attr.flags(s.olines[y1][x1].attr) & Attr::REVERSE).should_not eq 0
    (Attr.flags(s.lines[y1][x1].attr) & Attr::REVERSE).should eq 0

    # Move the cursor to a different row, with NO content change and no row
    # marked dirty. The vacated cell must revert to the real content.
    x2, y2 = 6, 3
    s.tput.cursor.x = x2
    s.tput.cursor.y = y2
    s.draw

    # Old position: cursor erased -> @olines mirrors the content again.
    (Attr.flags(s.olines[y1][x1].attr) & Attr::REVERSE).should eq 0
    s.olines[y1][x1].char.should eq '.'
    # New position: cursor now painted there.
    (Attr.flags(s.olines[y2][x2].attr) & Attr::REVERSE).should_not eq 0
  end

  it "erases the artificial cursor when it stops being drawn" do
    s = cursor_screen
    s.alloc
    s.lines.size.times { |y| s.lines[y].size.times { |x| s.lines[y][x].char = '.' } }
    s.lines.each &.dirty=(true)
    s.draw

    s.cursor.artificial = true
    s.cursor._hidden = false
    s.cursor._state = 1
    s.cursor.shape = Tput::CursorShape::Block

    x, y = 2, 2
    s.tput.cursor.x = x
    s.tput.cursor.y = y
    s.draw
    (Attr.flags(s.olines[y][x].attr) & Attr::REVERSE).should_not eq 0

    # Turn the artificial cursor off (e.g. handing control back to a hardware
    # cursor). The cursor's row is now no longer force-scanned, so without the
    # repair its glyph would linger; with no content change its cell must revert.
    s.cursor.artificial = false
    s.draw
    (Attr.flags(s.olines[y][x].attr) & Attr::REVERSE).should eq 0
    s.olines[y][x].char.should eq '.'
  end
end
