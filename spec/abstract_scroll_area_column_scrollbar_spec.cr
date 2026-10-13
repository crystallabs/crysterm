require "./spec_helper"

include Crysterm

# `AbstractScrollArea#line_wrap_column` beside an `AsNeeded` scroll bar: the
# bar takes its columns of the slack beside the column whether it shows or
# not, so its coming and going moves neither the text nor its wrap. Were the
# column to narrow for the bar, a paragraph on the edge could gain the row
# that keeps the bar and lose it a frame later — the layout alternating
# between frames with no change, the caret placed on one layout and the rows
# painted from the other.
describe "AbstractScrollArea line wrap column with a scroll bar" do
  it "keeps the column's width and the layout steady when the bar comes" do
    s = headless_screen(14, 6, default_quit_keys: true)
    te = Widget::PlainTextEdit.new(parent: s, left: 0, top: 0, width: "100%", height: "100%",
      content: "first line here\nsecond 漢字 line\n\nthird")
    te.line_wrap_column = 9
    te.focus
    s.repaint
    te.content_width.should eq 9
    te.show_scrollbar?.should be_false

    te.cursor_position = 5
    te._listener kp('\t') # "first\t line here" now wraps to one more row
    s.repaint
    te.show_scrollbar?.should be_true
    te.content_width.should eq 9
    rows = (0...6).map { |y| row_text(s, y) }
    3.times do
      s.repaint
      te.show_scrollbar?.should be_true
      te.content_width.should eq 9
      (0...6).map { |y| row_text(s, y) }.should eq rows
    end
  end

  it "keeps a right-aligned column beside the bar" do
    s = headless_screen(20, 4, default_quit_keys: true)
    te = Widget::PlainTextEdit.new(parent: s, left: 0, top: 0, width: "100%", height: "100%",
      content: (1..8).map { |i| "line #{i}" }.join('\n'))
    te.line_wrap_column = 10
    te.line_wrap_column_alignment = Tput::AlignFlag::Right
    s.repaint
    te.show_scrollbar?.should be_true
    te.content_width.should eq 10
    # The text's 10 columns and the caret's end-of-line column end before
    # the bar's.
    row_text(s, 3, 8...19).should eq "line 8     "
    row_text(s, 3, 19...20).should_not eq " "
  end
end
