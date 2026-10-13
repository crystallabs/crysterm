require "./spec_helper"

include Crysterm

# A TAB the wrap splits between two rows of a `Widget::TextEdit` paints on
# each row the part of its expansion the row holds, as the caret's geometry
# lays it out — not the whole expansion on the next row, which pushed the
# rest of that row right of where the caret and the mouse place it.
describe "TextEdit TAB split by the wrap" do
  it "paints each row's part of the TAB where the layout puts it" do
    s = headless_screen(12, 4, default_quit_keys: true)
    # Wrap width 11 (the caret's column reserved): "abcdefgh" and 3 of the
    # TAB's 4 columns on the first row, the last one and "Z" on the second.
    te = Widget::TextEdit.new(parent: s, left: 0, top: 0, width: 12, height: 4, content: "abcdefgh\tZ")
    te.focus
    s.repaint
    row_text(s, 0, 0...11).should eq "abcdefgh   "
    row_text(s, 1, 0...3).should eq " Z "
    te.cursor_position = 9 # the Z
    s.repaint
    {s.tput.cursor.x, s.tput.cursor.y}.should eq({1, 1})

    te.hide
    Widget::PlainTextEdit.new(parent: s, left: 0, top: 0, width: 12, height: 4, content: "abcdefgh\tZ")
    s.repaint
    row_text(s, 1, 0...3).should eq " Z "
  end
end
