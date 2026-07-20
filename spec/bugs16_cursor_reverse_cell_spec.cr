require "./spec_helper"

include Crysterm

# BUGS16.md #B16-05: the artificial Block-shape cursor OR'd Attr::REVERSE onto
# the cell's own attribute. On a cell that already carries REVERSE (text
# selections, the reverse-video focused/selected 'floor highlight'), OR is a
# no-op: the produced attribute is bit-for-bit identical to the cell's own
# attribute, so `draw` emits nothing and the cursor is invisible while it sits
# on a reversed cell. Fix: toggle (XOR) REVERSE instead of OR-ing it, matching
# real hardware block-cursor behavior (reverse of reverse = normal video).

private def cursor_screen(output = IO::Memory.new, width = 10, height = 4)
  Crysterm::Window.new(
    input: IO::Memory.new, output: output, error: IO::Memory.new,
    width: width, height: height)
end

describe "Window#_artificial_cursor_attr on already-reversed cells (#B16-05)" do
  it "flips REVERSE off (not a no-op) for a Block cursor over a reversed cell" do
    s = cursor_screen
    s.alloc

    x, y = 3, 1
    s.lines[y][x].char = 'A'
    s.lines[y][x].attr = Attr.pack(Attr::REVERSE, Attr.fg(s.lines[y][x].attr), Attr.bg(s.lines[y][x].attr))
    base_attr = s.lines[y][x].attr

    s.cursor.artificial = true
    s.cursor._hidden = false
    s.cursor._state = 1
    s.cursor.shape = Tput::CursorShape::Block

    attr, _ = s._artificial_cursor_attr(s.cursor, base_attr)

    # Must differ from the cell's own (already-reversed) attribute, otherwise
    # `draw` treats the cursor cell as unchanged and paints nothing.
    attr.should_not eq base_attr
    (Attr.flags(attr) & Attr::REVERSE).should eq 0
  end

  it "still sets REVERSE for a Block cursor over a normal (non-reversed) cell" do
    s = cursor_screen
    s.alloc

    x, y = 4, 2
    s.lines[y][x].char = 'B'
    base_attr = s.lines[y][x].attr
    (Attr.flags(base_attr) & Attr::REVERSE).should eq 0

    s.cursor.artificial = true
    s.cursor._hidden = false
    s.cursor._state = 1
    s.cursor.shape = Tput::CursorShape::Block

    attr, _ = s._artificial_cursor_attr(s.cursor, base_attr)

    attr.should_not eq base_attr
    (Attr.flags(attr) & Attr::REVERSE).should_not eq 0
  end

  it "draw paints a visibly different cell when the cursor sits on a reverse-styled selection" do
    s = cursor_screen
    s.alloc

    s.lines.size.times { |yy| s.lines[yy].size.times { |xx| s.lines[yy][xx].char = '.' } }

    # Simulate a reverse-video selected cell (e.g. TextEdit selection / list
    # 'floor highlight').
    x, y = 2, 2
    s.lines[y][x].char = 'S'
    s.lines[y][x].attr = Attr.pack(Attr::REVERSE, Attr.fg(s.lines[y][x].attr), Attr.bg(s.lines[y][x].attr))
    s.lines.each &.dirty=(true)
    s.draw

    s.cursor.artificial = true
    s.cursor._hidden = false
    s.cursor._state = 1
    s.cursor.shape = Tput::CursorShape::Block

    s.tput.cursor.x = x
    s.tput.cursor.y = y
    s.draw

    # The cursor cell in @flushed_lines must differ from the underlying
    # (reversed) content cell, otherwise it never got emitted/is invisible.
    (Attr.flags(s.flushed_lines[y][x].attr) & Attr::REVERSE).should eq 0
    (Attr.flags(s.lines[y][x].attr) & Attr::REVERSE).should_not eq 0
  end
end
