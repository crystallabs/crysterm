require "./spec_helper"

include Crysterm

private def hscreen(w = 40, h = 14)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new, width: w, height: h)
end

private def text_of(s) : String
  (0...s.aheight).map { |y| (0...s.awidth).map { |x| c = s.lines[y][x].char; c == '\0' ? ' ' : c }.join }.join("\n")
end

describe Crysterm::Widget::Graph::PieChart do
  it "draws slices as braille wedges and a legend with percentages" do
    s = hscreen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      pie = Crysterm::Widget::Graph::PieChart.new parent: s, top: 0, left: 0, width: 24, height: 13,
        type: Crysterm::Widget::Media::Type::Glyph, style: Crysterm::Style.new(border: true)
      pie.add_slice 50, 0x40E0D0, "web"
      pie.add_slice 30, 0xE0A040, "db"
      pie.add_slice 20, 0xE04060, "cache"
      s._render
      t = text_of s
      t.each_char.any? { |ch| ('⠁'..'⣿').includes?(ch) }.should be_true # wedges
      t.includes?("web").should be_true
      t.includes?("50%").should be_true
      t.includes?("20%").should be_true
      pie.slices.size.should eq 3
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "cycles the default palette when no color is given" do
    pie = Crysterm::Widget::Graph::PieChart.new width: 10, height: 6
    a = pie.add_slice 1
    b = pie.add_slice 1
    a.color.should eq Crysterm::Widget::Graph::PieChart::DEFAULT_COLORS[0]
    b.color.should eq Crysterm::Widget::Graph::PieChart::DEFAULT_COLORS[1]
  end

  it "draws nothing when the total is not positive" do
    s = hscreen(20, 11)
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      pie = Crysterm::Widget::Graph::PieChart.new parent: s, top: 0, left: 0, width: 20, height: 11,
        show_legend: false, type: Crysterm::Widget::Media::Type::Glyph,
        style: Crysterm::Style.new(border: true)
      pie.add_slice 0, 0x40E0D0, "none"
      s._render
      # No positive slice: the interior stays free of any wedge glyphs.
      interior = (1..9).map { |y| (1...19).map { |x| s.lines[y][x].char }.join }
      interior.all? { |row| row.each_char.none? { |ch| ('⠁'..'⣿').includes?(ch) } }.should be_true
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "honors inner_radius (ring) as a fraction of the outer radius" do
    pie = Crysterm::Widget::Graph::PieChart.new width: 10, height: 6, inner_radius: 0.5
    pie.inner_radius.should eq 0.5
    pie.inner_radius = 0.25
    pie.inner_radius.should eq 0.25
  end
end
