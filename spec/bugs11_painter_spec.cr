require "./spec_helper"

include Crysterm

# Regression specs for BUGS11 findings #9 and #13, both in
# src/widget_graph_painter.cr.
#
#  #9 [HIGH]: Painter#dx/#dy (and draw_ellipse / fill_ring plot coords) did
#     `.round.to_i` on a Float64 with no finiteness/range guard. In Crystal
#     Float64#to_i raises OverflowError on NaN, Infinity or out-of-Int32 values,
#     which unwound and killed the render fiber. A NaN/Infinity/1e18 data point
#     (ordinary from 0/0, log(0), missing samples, or outliers against a pinned
#     axis) now maps to an off-canvas sentinel (Int32::MIN, rejected by #plot's
#     bounds check) or is clamped — never raising.
#
#  #13 [LOW]: Painter#fill_ring looped forever when step_deg <= 0 (a positive
#     sweep never reaches `stop`), and NaN angles either looped forever or
#     crashed on the first NaN->Int32 conversion. fill_ring now bails on
#     non-finite start/stop and clamps a non-positive/non-finite step to 0.7.

private def new_painter(w = 80, h = 24)
  bmp = Array(Array(PNGGIF::Pixel)).new(h) do
    Array(PNGGIF::Pixel).new(w, PNGGIF::Pixel.new(0, 0, 0, 0))
  end
  Widget::Graph::Painter.new(bmp)
end

# Count pixels that were actually painted (alpha > 0).
private def painted_pixels(p : Widget::Graph::Painter) : Int32
  bmp = p.@bmp
  n = 0
  bmp.each { |row| row.each { |px| n += 1 if px.a > 0 } }
  n
end

describe "BUGS11 Painter" do
  describe "#9 non-finite / huge logical coordinates don't crash the transform" do
    it "draw_point with NaN/Infinity does not raise and plots nothing" do
      p = new_painter
      p.draw_point(Float64::NAN, Float64::NAN)
      p.draw_point(Float64::INFINITY, 0.0)
      p.draw_point(0.0, -Float64::INFINITY)
      painted_pixels(p).should eq 0
    end

    it "draw_point with a huge finite value is clamped off-canvas (no crash, no plot)" do
      p = new_painter
      p.draw_point(1e18, 1e18)
      painted_pixels(p).should eq 0
    end

    it "draw_marker / draw_line / draw_polyline with NaN do not raise" do
      p = new_painter
      p.draw_marker(Float64::NAN, Float64::NAN, 2)
      p.draw_line(0.0, 0.0, Float64::NAN, Float64::INFINITY)
      p.draw_polyline([{0.0, 0.0}, {Float64::NAN, 1.0}, {1e18, 2.0}])
      # None of the non-finite endpoints crash; nothing is asserted about the
      # finite-to-finite line here beyond "did not raise".
    end

    it "draw_ellipse with NaN / huge radii does not raise" do
      p = new_painter
      p.draw_ellipse(40.0, 12.0, Float64::NAN, 5.0)
      p.draw_ellipse(40.0, 12.0, 1e18, 1e18)
    end

    it "still plots for ordinary finite coordinates (guard doesn't over-reject)" do
      p = new_painter
      p.draw_point(40.0, 12.0)
      painted_pixels(p).should be > 0
    end
  end

  describe "#13 fill_ring degenerate angle/step inputs terminate" do
    it "returns without hanging when step_deg <= 0" do
      p = new_painter
      p.fill_ring(40.0, 12.0, 3.0, 8.0, 0.0, 360.0, step_deg: 0.0)
      p.fill_ring(40.0, 12.0, 3.0, 8.0, 0.0, 360.0, step_deg: -5.0)
      # Reaching here means neither call spun forever; a positive default step
      # was substituted, so the ring is actually drawn.
      painted_pixels(p).should be > 0
    end

    it "returns without hanging or raising when angle args are NaN" do
      p = new_painter
      p.fill_ring(40.0, 12.0, 3.0, 8.0, Float64::NAN, 360.0)
      p.fill_ring(40.0, 12.0, 3.0, 8.0, 0.0, Float64::NAN)
      p.fill_ring(40.0, 12.0, 3.0, 8.0, Float64::NAN, Float64::NAN)
      # NaN start/stop are rejected up front: no infinite loop and no
      # NaN->Int32 OverflowError from the plot conversion.
      painted_pixels(p).should eq 0
    end
  end
end
