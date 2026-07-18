require "./spec_helper"

include Crysterm

# Regression coverage for the artificial cursor in `Window#draw`
# (`window_drawing.cr`).
#
# `draw` only scans a row when it is dirty or currently holds the cursor. The
# artificial cursor is composited into the cell at `(tput.cursor.x, cursor.y)`
# and written into `@flushed_lines` (mirroring the terminal). When the cursor moves to
# another row with no buffer change, that old row isn't otherwise dirty — so
# without explicit repair, the stranded cursor glyph never diffs away and
# leaves a ghost cursor.
private def cursor_screen(output = IO::Memory.new, width = 10, height = 4)
  Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
end

describe "Window#draw artificial cursor movement" do
  it "erases the artificial cursor from the row it leaves" do
    s = cursor_screen
    s.alloc

    # Stable content; primes @flushed_lines to mirror @lines (default cursor is
    # hardware, so nothing artificial painted yet).
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

    # Cursor cell now carries REVERSE in @flushed_lines; content cell does not.
    (Attr.flags(s.flushed_lines[y1][x1].attr) & Attr::REVERSE).should_not eq 0
    (Attr.flags(s.lines[y1][x1].attr) & Attr::REVERSE).should eq 0

    # Move to a different row: no content change, no row marked dirty. The
    # vacated cell must revert to the real content.
    x2, y2 = 6, 3
    s.tput.cursor.x = x2
    s.tput.cursor.y = y2
    s.draw

    # Old position: erased, @flushed_lines mirrors content again.
    (Attr.flags(s.flushed_lines[y1][x1].attr) & Attr::REVERSE).should eq 0
    s.flushed_lines[y1][x1].char.should eq '.'
    # New position: cursor painted there.
    (Attr.flags(s.flushed_lines[y2][x2].attr) & Attr::REVERSE).should_not eq 0
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
    (Attr.flags(s.flushed_lines[y][x].attr) & Attr::REVERSE).should_not eq 0

    # Turning artificial off means the row is no longer force-scanned; without
    # repair the glyph would linger. No content change, so the cell must revert.
    s.cursor.artificial = false
    s.draw
    (Attr.flags(s.flushed_lines[y][x].attr) & Attr::REVERSE).should eq 0
    s.flushed_lines[y][x].char.should eq '.'
  end
end
