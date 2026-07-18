require "./spec_helper"

include Crysterm

# Regression: off-screen (negative-coordinate) clipping in `Widget#_render`
# (`widget_rendering.cr`).
#
# A top-level widget positioned partly off the left or top screen edge has a
# rendered rectangle whose `xi`/`yi` is negative. The content- and border-draw
# loops index the cell buffer with `lines[y]?`/`line[x]?`, and Crystal's
# `Indexable#[]?` counts a negative index from the end (`line[-1]?` is the last
# cell, not `nil`). Before this fix, off-screen columns/rows wrapped around and
# painted onto the opposite (right/bottom) edge instead of vanishing. The fix
# consumes the off-screen edge (keeping the on-screen portion aligned) but never
# writes it.
private def screen(width = 12, height = 4)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

describe "Widget#_render off-screen clipping" do
  it "clips a widget off the LEFT edge without wrapping onto the right edge" do
    s = screen width: 12, height: 3
    s.alloc
    b = Crysterm::Widget::Box.new(left: -3, top: 0, width: 6, height: 1, content: "ABCDEF")
    s << b
    s._render

    row = s.lines[0]
    chars = (0...row.size).map { |x| row[x].char }.join

    # The on-screen portion shows the widget's columns 3.. ("DEF") at column 0.
    chars[0, 3].should eq "DEF"
    # The off-screen-left columns (-3,-2,-1) must not wrap onto the right edge:
    # right cells stay blank instead of showing "ABC".
    chars[9, 3].should eq "   "
  end

  it "clips a widget off the TOP edge without wrapping onto the bottom rows" do
    s = screen width: 6, height: 5
    s.alloc
    # Four content rows ("aaaa".."dddd"); the top two rows sit above the screen.
    b = Crysterm::Widget::Box.new(left: 0, top: -2, width: 4, height: 4,
      content: "aaaa\nbbbb\ncccc\ndddd")
    s << b
    s._render

    def_char = Crysterm::Window::DEFAULT_CHAR

    # On-screen rows 0,1 show the widget's rows 2,3 ("cccc","dddd").
    (0...4).map { |x| s.lines[0][x].char }.join.should eq "cccc"
    (0...4).map { |x| s.lines[1][x].char }.join.should eq "dddd"
    # The off-screen-top rows must not wrap onto the bottom rows: rows 3 and 4
    # stay blank (would have been "aaaa"/"bbbb" before the fix).
    (0...4).all? { |x| s.lines[3][x].char == def_char }.should be_true
    (0...4).all? { |x| s.lines[4][x].char == def_char }.should be_true
  end

  it "does not wrap a left-clipped border onto the right edge" do
    s = screen width: 12, height: 3
    s.alloc
    b = Crysterm::Widget::Box.new(left: -2, top: 0, width: 6, height: 3, content: "")
    b.style.border = Crysterm::Border.new(type: Crysterm::BorderType::Solid)
    s << b
    s._render

    def_char = Crysterm::Window::DEFAULT_CHAR
    # The widget occupies columns -2..3; its right border lands on column 3.
    # The off-screen-left border column must not wrap to the far right.
    (9...12).each do |x|
      (0...3).each do |y|
        s.lines[y][x].char.should eq def_char
      end
    end
  end
end
