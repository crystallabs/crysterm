require "./spec_helper"

include Crysterm

# `AbstractScrollArea#line_wrap_column`: the text laid out in a column
# narrower than the viewport, placed by `#line_wrap_column_alignment` —
# the wrap width, the painted origin, the caret and the mouse all counted
# from the column, and the scroll bar left at the frame.

private WORDS = "aaaa bbbb cccc dddd eeee ffff gggg hhhh"

describe "AbstractScrollArea#line_wrap_column" do
  it "is off by default and the text runs to the viewport's width" do
    s = headless_screen(40, 6)
    te = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 6
    te.set_markdown WORDS
    s.repaint
    te.line_wrap_column.should eq 0
    te.line_wrap_column_alignment.should eq Tput::AlignFlag::Left
    row_text(s, 0).should eq WORDS
  end

  it "wraps the viewer at the column, left-aligned, then centered" do
    s = headless_screen(40, 6)
    te = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 6
    te.set_markdown WORDS
    te.line_wrap_column = 20
    s.repaint
    row_text(s, 0).should eq "aaaa bbbb cccc dddd"
    row_text(s, 1).should eq "eeee ffff gggg hhhh"

    te.line_wrap_column_alignment = Tput::AlignFlag::HCenter
    s.repaint
    # 39 text columns (the editing mixin keeps one for the caret), 19 of
    # slack: 9 left, 10 right.
    row_text(s, 0).should eq "         aaaa bbbb cccc dddd"
    row_text(s, 1).should eq "         eeee ffff gggg hhhh"
    te.ileft.should eq 9
    # The caret and the mouse count from the column's edge.
    te.cursor_position = 5
    s.repaint
    te.cursor_viewport_row.should eq 0
    te.position_at(14, 1).should eq te.document.block_position(0) + 25

    te.line_wrap_column = 0
    s.repaint
    row_text(s, 0).should eq WORDS
    te.ileft.should eq 0
  end

  it "keeps the scroll bar at the frame and the text's width exact beside it" do
    s = headless_screen(40, 4)
    te = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 40, height: 4
    te.set_markdown (1..10).map { |i| "Line #{i} #{WORDS}" }.join("\n\n")
    te.line_wrap_column = 20
    te.line_wrap_column_alignment = Tput::AlignFlag::HCenter
    s.repaint
    s.repaint # the bar's reservation settles on the second frame
    te.vertical_scrollbar.visible?.should be_true
    te.vertical_scrollbar.aleft.should eq 39
    # The bar's column and the caret's come off the slack: 18 left, 9 a side.
    row_text(s, 0, 0..8).should eq "         "
    row_text(s, 0, 9..28).strip.should eq "Line 1 aaaa bbbb"
    row_text(s, 1, 9..28).strip.should eq "cccc dddd eeee ffff"
  end

  it "lays the plain text editor out in the column too, caret included" do
    s = headless_screen(40, 6)
    pe = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6, content: WORDS
    pe.line_wrap_column = 20
    pe.line_wrap_column_alignment = Tput::AlignFlag::HCenter
    s.repaint
    # 20 columns of text plus the caret's own column: the break falls as in
    # a 21-wide editor.
    row_text(s, 0).should eq "         aaaa bbbb cccc dddd"
    row_text(s, 1).should eq "         eeee ffff gggg hhhh"
    pe.ileft.should eq 9
    pe.cursor_position = 2
    s.repaint
    s.tput.cursor.x.should eq 11
    pe.position_at(9, 1).should eq 20
  end
end
