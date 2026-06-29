require "./spec_helper"

include Crysterm

private def chart_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 50, height: 16)
end

private def rows(s) : Array(String)
  (0...s.aheight).map { |y| (0...s.awidth).map { |x| c = s.lines[y][x].char; c == '\0' ? ' ' : c }.join }
end

describe Crysterm::Widget::Graph::LineChart do
  it "renders title, legend, axis labels (text) and a braille plot" do
    s = chart_screen
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      c = Crysterm::Widget::Graph::LineChart.new parent: s, top: 0, left: 0, width: 50, height: 16,
        title: "Signals", type: Crysterm::Widget::Media::Type::Glyph,
        style: Crysterm::Style.new(border: true)
      c.add_line "sin", (0..60).map { |i| {i / 10.0, Math.sin(i / 10.0)} }
      c.add_line "cos", (0..60).map { |i| {i / 10.0, Math.cos(i / 10.0)} }
      c.axis_y.minimum = -1.0
      c.axis_y.maximum = 1.0
      s._render

      text = rows(s)
      all = text.join("\n")
      # Chrome (terminal text)
      text.any?(&.includes?("Signals")).should be_true # title
      all.includes?("■").should be_true                # legend swatch
      all.includes?("sin").should be_true              # legend name
      all.includes?("-0.5").should be_true             # a Y tick label
      all.includes?("4.5").should be_true              # an X tick label
      # Plot (braille glyphs)
      text.any? { |r| r.each_char.any? { |ch| ('⠁'..'⣿').includes?(ch) } }.should be_true
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "auto-assigns palette colors and supports scatter/area kinds" do
    s = chart_screen
    c = Crysterm::Widget::Graph::LineChart.new parent: s, width: 40, height: 10,
      type: Crysterm::Widget::Media::Type::Glyph
    a = c.add_line "a", [{0.0, 0.0}, {1.0, 1.0}]
    b = c.add_scatter "b", [{0.0, 1.0}, {1.0, 0.0}]
    d = c.add_area "c", [{0.0, 0.5}]
    a.color.should eq Crysterm::Widget::Graph::LineChart::PALETTE[0]
    b.color.should eq Crysterm::Widget::Graph::LineChart::PALETTE[1]
    b.kind.scatter?.should be_true
    d.kind.area?.should be_true
    c.series.size.should eq 3
  end
end
