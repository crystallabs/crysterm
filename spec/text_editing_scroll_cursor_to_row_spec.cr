require "./spec_helper"

include Crysterm

# `Mixin::TextEditing#scroll_cursor_to_row` puts the caret on a chosen
# viewport row (`#ensure_cursor_visible` only brings it to the nearest
# edge); `#cursor_viewport_row` reads it back, and `#center_cursor` is the
# Qt `centerCursor` on top of them.

private def editor(s, lines = 60)
  e = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8
  e.plain_text = (1..lines).map { |i| "line #{i}" }.join("\n")
  s.repaint
  e
end

# The buffer position of the start of 1-based *line* in `editor`'s text.
private def line_start(e, line)
  e.document.block_position(line - 1)
end

describe "TextEditing#scroll_cursor_to_row" do
  it "scrolls so the caret sits on the given viewport row" do
    s = headless_screen(40, 8)
    e = editor s
    e.cursor_position = line_start(e, 30)
    e.scroll_cursor_to_row 3
    s.repaint
    e.cursor_viewport_row.should eq 3
    e.scroll_position.should eq e.cursor_row - 3
    e.scroll_cursor_to_row 0
    s.repaint
    e.cursor_viewport_row.should eq 0
    s.destroy
  end

  it "stops at the document's ends, leaving the caret where the content allows" do
    s = headless_screen(40, 8)
    e = editor s
    e.cursor_position = line_start(e, 2)
    e.scroll_cursor_to_row 6
    s.repaint
    e.scroll_position.should eq 0
    e.cursor_viewport_row.should eq 1
    s.destroy
  end

  it "center_cursor puts the caret on the middle row" do
    s = headless_screen(40, 8)
    e = editor s
    e.cursor_position = line_start(e, 30)
    e.center_cursor
    s.repaint
    e.cursor_viewport_row.should eq 4
    s.destroy
  end

  it "aligns two views on the same viewport row" do
    s = headless_screen(40, 8)
    a = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 8
    b = Widget::PlainTextEdit.new parent: s, left: 20, top: 0, width: 20, height: 8
    text = (1..60).map { |i| "line #{i}" }.join("\n")
    a.plain_text = text
    b.plain_text = text
    s.repaint
    a.cursor_position = line_start(a, 40)
    a.scroll_cursor_to_row 2
    b.cursor_position = line_start(b, 40)
    b.scroll_cursor_to_row a.cursor_viewport_row
    s.repaint
    b.cursor_viewport_row.should eq 2
    b.scroll_position.should eq a.scroll_position
    s.destroy
  end
end
