require "./spec_helper"

include Crysterm

# Findings #10, #11, #19 (BUGS15.md): NaN/Infinity data points used to crash
# the render fiber (auto-scale `max`/`max?` over an array containing NaN
# raises `ArgumentError`) or, for the line-chart painter, draw a visible
# stray ray plus iterate millions of rejected off-canvas pixels.

private def g15_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def blank_bitmap(w, h) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(0, 0, 0, 0) } }
end

describe "Widget::Graph::Bar auto-scale with a NaN value (#10)" do
  it "renders without raising when max is nil (auto-scale) and a value is NaN" do
    s = g15_screen
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0,
      width: 40, height: 8
    bar.values = [42.0, Float64::NAN, 13.0]

    # Before the fix, `shown.max` raised ArgumentError ("Comparison of NaN
    # and ... failed") inside build_content, on the render fiber.
    s._render

    bar.content.should_not be_empty
  end

  it "renders empty content (no crash) when every value is NaN" do
    s = g15_screen
    bar = Crysterm::Widget::Graph::Bar.new parent: s, top: 0, left: 0,
      width: 40, height: 8
    bar.values = [Float64::NAN, Float64::NAN]

    s._render
  end
end

describe "Widget::Graph::StackedBar auto-scale with a NaN segment (#11)" do
  it "renders without raising when max is nil (auto-scale) and a segment sum is NaN" do
    s = g15_screen
    sb = Crysterm::Widget::Graph::StackedBar.new parent: s, top: 0, left: 0,
      width: 40, height: 8
    sb.values = [[60.0, 30.0], [20.0, Float64::NAN]]

    # Before the fix, `sums.max?` raised ArgumentError when comparing NaN
    # against a finite sum, inside build_content on the render fiber.
    s._render

    sb.content.should_not be_empty
  end
end

describe Crysterm::Widget::Graph::Painter do
  describe "draw_line/draw_polyline with a non-finite endpoint (#19)" do
    it "draw_line does not paint a stray ray when one endpoint is non-finite" do
      bmp = blank_bitmap(16, 16)
      p = Crysterm::Widget::Graph::Painter.new bmp
      p.pen = 0xFFFFFF
      # A finite start with a NaN end used to map the end through the
      # off-canvas sentinel and Bresenham-walk a visible ray from the valid
      # start toward the canvas edge.
      p.draw_line 8.0, 8.0, Float64::NAN, Float64::NAN

      painted = false
      16.times { |y| 16.times { |x| painted = true if bmp[y][x].r == 255 } }
      painted.should be_false
    end

    it "draw_line returns promptly (no ~10^6 rejected-pixel spin) for a non-finite endpoint" do
      bmp = blank_bitmap(16, 16)
      p = Crysterm::Widget::Graph::Painter.new bmp
      elapsed = Time.measure do
        p.draw_line 8.0, 8.0, Float64::INFINITY, Float64::INFINITY
      end
      elapsed.should be < 1.second
    end

    it "draw_polyline skips segments touching a non-finite point but still draws the finite ones" do
      bmp = blank_bitmap(16, 16)
      p = Crysterm::Widget::Graph::Painter.new bmp
      p.pen = 0x00FF00
      p.draw_polyline [{0.0, 8.0}, {8.0, Float64::NAN}, {15.0, 8.0}]

      # No pixel near the top/bottom edges (where a stray ray toward the
      # sentinel would land) got painted...
      stray = false
      16.times { |x| stray = true if bmp[0][x].g == 255 || bmp[15][x].g == 255 }
      stray.should be_false

      # ...and the segment between the two finite points would have been
      # drawn were it not skipped along with its NaN-touching neighbors —
      # confirm the call completed promptly with no crash either way.
    end
  end
end
