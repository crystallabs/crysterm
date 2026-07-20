require "./spec_helper"

include Crysterm

# Regression: a border side thicker than one cell used to reserve the space
# (shrinking the content area) but draw the glyphs only in the outermost
# row/column, leaving the inner reserved band blank. `Widget#base_render` now fills
# the whole band, classifying each cell as a horizontal run, a vertical run, or
# a corner/join cell so the right glyph lands everywhere.
private def screen(width, height)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: width, height: height)
end

private def rows(s)
  (0...s.lines.size).map do |y|
    row = s.lines[y]
    (0...row.size).map { |x| row[x].char }.join
  end
end

describe "thick border band fill" do
  it "fills a 2-cell-thick Fill border with per-position chars" do
    s = screen 6, 6
    s.alloc
    b = Crysterm::Widget::Box.new(left: 0, top: 0, width: 6, height: 6, content: "")
    b.style.border = Crysterm::Border.new(type: Crysterm::BorderType::Fill, left: 2, top: 2, right: 2, bottom: 2)
    b.style.border.not_nil!.horizontal_char = 'h'
    b.style.border.not_nil!.vertical_char = 'v'
    b.style.border.not_nil!.corner_char = 'c'
    s << b
    s.repaint

    r = rows s
    # 2-thick border all around a 6x6 box leaves a 2x2 interior at (2..3,2..3).
    # Corner blocks are the 2x2 cells at each corner; the top/bottom runs use
    # 'h', the left/right runs use 'v'.
    r[0].should eq "cchhcc"
    r[1].should eq "cchhcc"
    r[2].should eq "vv  vv"
    r[3].should eq "vv  vv"
    r[4].should eq "cchhcc"
    r[5].should eq "cchhcc"
  end

  it "fills a 2-cell-thick Solid border with repeated run glyphs and corners" do
    s = screen 6, 6
    s.alloc
    b = Crysterm::Widget::Box.new(left: 0, top: 0, width: 6, height: 6, content: "")
    b.style.border = Crysterm::Border.new(type: Crysterm::BorderType::Solid, left: 2, top: 2, right: 2, bottom: 2)
    s << b
    s.repaint

    r = rows s
    r[0].should eq "┌┌──┐┐"
    r[1].should eq "┌┌──┐┐"
    r[2].should eq "││  ││"
    r[3].should eq "││  ││"
    r[4].should eq "└└──┘┘"
    r[5].should eq "└└──┘┘"
  end

  it "still draws a 1-cell border as a single ring" do
    s = screen 4, 4
    s.alloc
    b = Crysterm::Widget::Box.new(left: 0, top: 0, width: 4, height: 4, content: "")
    b.style.border = Crysterm::Border.new(type: Crysterm::BorderType::Solid)
    s << b
    s.repaint

    r = rows s
    r[0].should eq "┌──┐"
    r[1][0].should eq '│'
    r[1][3].should eq '│'
    r[3].should eq "└──┘"
  end
end
