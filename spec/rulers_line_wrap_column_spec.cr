require "./spec_helper"

include Crysterm

# `AbstractScrollArea#line_wrap_column=` changed after the widget is shown:
# the column ruler's tape and the guides' bounds follow the text's new
# column on the next frame, the same as a widget given the column before its
# first render.

private def viewer(s, content)
  Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6, content: content
end

private def rows(s)
  (0...6).map { |y| row_text(s, y) }
end

# The rows a fresh viewer with the rulers and guides draws for *column* and
# *alignment*, set before its first render.
private def fresh_rows(column, alignment = Tput::AlignFlag::Left)
  s = headless_screen(40, 6)
  te = viewer(s, "hello world")
  te.rulers = true
  te.guides_enabled = true
  te.line_wrap_column = column
  te.line_wrap_column_alignment = alignment
  s.repaint
  rows(s)
end

describe "AbstractScrollArea rulers, the text's column changed at runtime" do
  it "ends the tape and moves the bounds with the new column, and back" do
    s = headless_screen(40, 6)
    te = viewer(s, "hello world")
    te.rulers = true
    te.guides_enabled = true
    s.repaint
    # The full width: the tape runs on past column 20.
    row_text(s, 0, 21..23).should eq "│20"
    full = rows(s)

    te.line_wrap_column = 20
    s.repaint
    # Two ruler columns, then columns 1 to 20; nothing past the column and
    # its caret cell.
    row_text(s, 0, 2..21).should eq "────┼────│10──┼────│"
    row_text(s, 0, 24..39).should eq " " * 16
    te.text_column_bounds.should eq({0, 21})
    rows(s).should eq fresh_rows(20)

    te.line_wrap_column_alignment = Tput::AlignFlag::HCenter
    te.line_wrap_column = 8
    s.repaint
    rows(s).should eq fresh_rows(8, Tput::AlignFlag::HCenter)
    te.text_column_bounds.should eq({0, 9})

    te.line_wrap_column = 0
    s.repaint
    rows(s).should eq full
  end
end
