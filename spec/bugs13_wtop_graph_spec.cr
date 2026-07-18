require "./spec_helper"

include Crysterm

# Regression specs for the BUGS13 "Widget top-level" graph findings:
#
# * W11 — `Painter#fill_rect` clamps its loop bounds to the bitmap after the
#   coordinate swap, so a non-finite or far-off-canvas rect returns promptly
#   (pre-fix, `to_px` mapped non-finite coords to the ±PX_LIMIT sentinel and
#   the loops iterated the full sentinel span — ~10^12 plot calls for a
#   NaN×NaN rect, wedging the render fiber).
# * W12 — `Painter#fill_ring` refines its angular spoke step by the outer
#   radius (adjacent spokes ≤ ~0.5 px apart at the outer rim, floored at
#   0.05°), so large-radius rings show no radial pinhole banding (the fixed
#   0.7° step left gaps for r ≳ 100).
# * W13 — `Graph::Scale.fmt` guards the whole-number `to_i64` branch
#   (`return v.to_s unless v.finite? && v.abs < 9.2e18`), so finite values
#   beyond Int64 — and Infinity/NaN — format instead of raising
#   OverflowError (reachable from a HeatMap fed `1e19`).

private def graph_screen(w = 40, h = 15)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h, default_quit_keys: false)
end

private def blank_bitmap(w, h) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(0, 0, 0, 0) } }
end

private def filled_count(bmp)
  bmp.sum { |row| row.count { |px| px.a > 0 } }
end

describe "BUGS13 W11: Painter#fill_rect clamps its iteration to the bitmap" do
  it "returns promptly for non-finite rects without touching the canvas" do
    bmp = blank_bitmap 8, 8
    p = Widget::Graph::Painter.new bmp
    nan = Float64::NAN
    inf = Float64::INFINITY
    started = Time.instant
    p.fill_rect nan, nan, nan, nan
    p.fill_rect inf, 0, 10, 10
    p.fill_rect 0, -inf, 5, nan
    p.fill_rect nan, 2, 3, 3
    # Completing at all proves the fix (pre-fix each call iterated ~10^12
    # pixels); the bound just keeps a regression from hanging the suite.
    (Time.instant - started).should be < 10.seconds
    filled_count(bmp).should eq 0
  end

  it "returns promptly for far-off-canvas rects without touching the canvas" do
    bmp = blank_bitmap 8, 8
    p = Widget::Graph::Painter.new bmp
    p.fill_rect 500_000, 500_000, 1_000, 1_000
    p.fill_rect -500_000, -500_000, 1_000, 1_000
    p.fill_rect -2.0e9, -2.0e9, 10, 10
    filled_count(bmp).should eq 0
  end

  it "a huge rect overlapping the canvas clips to (and fills) the canvas" do
    bmp = blank_bitmap 8, 8
    p = Widget::Graph::Painter.new bmp
    p.fill_rect -100_000, -100_000, 200_000, 200_000
    filled_count(bmp).should eq 64
  end

  it "an in-bounds fill still fills exactly its pixels" do
    bmp = blank_bitmap 8, 8
    p = Widget::Graph::Painter.new bmp
    p.fill_rect 2, 2, 3, 3
    # fill_rect paints the inclusive device span dx(x)..dx(x+w) — here 2..5
    # on both axes.
    filled_count(bmp).should eq 16
    bmp[3][3].a.should eq 255
    bmp[1][1].a.should eq 0
    bmp[6][6].a.should eq 0
  end
end

describe "BUGS13 W12: Painter#fill_ring spoke density at large radii" do
  it "leaves no pinholes inside a large-radius annulus" do
    size = 331
    bmp = blank_bitmap size, size
    p = Widget::Graph::Painter.new bmp
    c = (size - 1) / 2.0
    ri = 100.0
    ro = 160.0
    p.fill_ring c, c, ri, ro

    # Every pixel whose center lies safely inside the annulus band must be
    # painted (pre-fix the fixed 0.7° spokes were ~1.8 px apart tangentially
    # at r=150, leaving unpainted pinholes); pixels safely outside the band
    # must stay untouched.
    holes = 0
    leaks = 0
    size.times do |y|
      size.times do |x|
        r = Math.hypot(x - c, y - c)
        if r >= ri + 1.0 && r <= ro - 1.0
          holes += 1 if bmp[y][x].a == 0
        elsif r < ri - 1.0 || r > ro + 1.0
          leaks += 1 if bmp[y][x].a > 0
        end
      end
    end
    holes.should eq 0
    leaks.should eq 0
  end

  it "a partial sweep fills only its sector of the band" do
    size = 331
    bmp = blank_bitmap size, size
    p = Widget::Graph::Painter.new bmp
    c = (size - 1) / 2.0
    # 0° is up, clockwise: 0..90° covers the upper-right quadrant.
    p.fill_ring c, c, 100.0, 160.0, 0.0, 90.0

    # Mid-sector sample (45°: up-right diagonal) is filled...
    d = 130.0 / Math.sqrt(2.0)
    bmp[(c - d).round.to_i][(c + d).round.to_i].a.should be > 0
    # ...the opposite quadrant (225°: down-left) is not.
    bmp[(c + d).round.to_i][(c - d).round.to_i].a.should eq 0
  end
end

describe "BUGS13 W13: Scale.fmt for values beyond Int64" do
  it "formats finite values beyond Int64 without raising" do
    Widget::Graph::Scale.fmt(1.0e19).should eq 1.0e19.to_s
    Widget::Graph::Scale.fmt(-1.0e19).should eq (-1.0e19).to_s
  end

  it "formats non-finite values as their plain strings" do
    Widget::Graph::Scale.fmt(Float64::INFINITY).should eq "Infinity"
    Widget::Graph::Scale.fmt(-Float64::INFINITY).should eq "-Infinity"
    Widget::Graph::Scale.fmt(Float64::NAN).should eq "NaN"
  end

  it "keeps the compact formatting for normal values" do
    Widget::Graph::Scale.fmt(5.0).should eq "5"
    Widget::Graph::Scale.fmt(-2.0).should eq "-2"
    Widget::Graph::Scale.fmt(3.14).should eq "3.1"
    # Still within Int64 (< 9.2e18): whole-number branch as before.
    Widget::Graph::Scale.fmt(9.0e18).should eq "9000000000000000000"
  end

  it "a HeatMap fed values beyond Int64 renders without OverflowError" do
    s = graph_screen
    Widget::Graph::HeatMap.new parent: s, top: 0, left: 0, width: 24, height: 10,
      values: [[1.0e19, 2.0e19], [3.0e18, 4.0e18]]
    s._render # the legend labels run Scale.fmt over the resolved bounds
  ensure
    s.try &.destroy
  end
end
