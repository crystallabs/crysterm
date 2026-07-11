require "./spec_helper"

include Crysterm

# Regression specs for BUGS14 findings A3, A4, A5.
#
# * A3 — `Calendar#build_content` (ISO-week gutter) added `thursday_offset.days`
#   to a row date that, for the last grid row of December 9999 (the default
#   `@maximum_date`), lands in January of year 10000 — outside Crystal's `Time`
#   range — and raised `ArgumentError` out of the un-rescued `visual` setter.
#   The computation is now rescued to a blank gutter.
# * A4 — `Spray#@frame` was an `Int32` frame counter; `@frame * 9`/`* 6` in
#   `#colorize` raise `OverflowError` past `Int32::MAX / 9 ≈ 2.4e8` frames.
#   Widened to `Int64` (matching `CopperBar`/`TextScroll`) so it never wraps.
# * A5 — an explicit non-finite `#vmin`/`#vmax` poisoned `HeatMap`'s color
#   scale, so `color_for`/`draw_legend` computed `NaN.round.to_i` →
#   `OverflowError`. Explicit bounds are now sanitized in `resolved_bounds`
#   (non-finite falls back to the finite data range) with a belt-and-braces
#   `t = 0.0 unless t.finite?` guard in `color_for`.

private def bugs14_screen(w = 40, h = 20)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h, default_quit_keys: false)
end

describe "BUGS14 A3: Calendar ISO week numbers at December 9999" do
  it "does not raise when the shown page is December 9999" do
    s = bugs14_screen
    cal = Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
      date: Time.utc(9999, 12, 15)
    # Turning on the ISO-week gutter reruns `build_content` for the Dec 9999
    # page; pre-fix its last row pushed a Thursday into year 10000 → ArgumentError.
    cal.vertical_header_format = Widget::Calendar::VerticalHeaderFormat::ISOWeekNumbers
    cal.year_shown.should eq 9999
    cal.month_shown.should eq 12
    s._render
  ensure
    s.try &.destroy
  end

  it "renders normal months with ISO week numbers as before (no regression)" do
    s = bugs14_screen
    cal = Widget::Calendar.new parent: s, top: 0, left: 0, width: 24, height: 12,
      date: Time.utc(2024, 1, 15)
    cal.vertical_header_format = Widget::Calendar::VerticalHeaderFormat::ISOWeekNumbers
    # Jan 1-6 2024 is ISO week 1 (identified by its Thursday) — the gutter must
    # still be computed for a normal month.
    cal.content.should contain "Wk"
    cal.content.should contain " 1"
    s._render
  ensure
    s.try &.destroy
  end
end

describe "BUGS14 A4: Spray frame counter is Int64 (no overflow on long loops)" do
  # The overflow only bites past ~2.4e8 frames, which can't be driven in a
  # spec; these prove the Int64-widened paths compile and render without
  # regression (the fix is the `@frame : Int64` type widening plus the
  # `@frame.to_i32!` wrap where the counter feeds the Int32 color proc).
  it "advances and colorizes many frames without raising" do
    spray = Widget::Effect::Spray.new width: 10, height: 5
    spray.resize 10, 5
    # Drive well past `travel` so pending/flight/landed branches of `#colorize`
    # all run, each reading `@frame` in an Int64 multiply.
    200.times { spray.advance 10, 5 }
    spray.cell(0, 0, 10, 5).should_not be_nil
  end

  it "runs the custom color proc (Int32 frame param) without raising" do
    seen = [] of Int32
    spray = Widget::Effect::Spray.new width: 8, height: 4,
      color: ->(_i : Int32, frame : Int32, _phase : Symbol) { seen << frame; 0x00ff00 }
    spray.resize 8, 4
    50.times { spray.advance 8, 4 }
    # The proc received the (wrapped-to-Int32) frame and produced a color.
    seen.empty?.should be_false
    spray.cell(0, 0, 8, 4)[1].should eq 0x00ff00
  end

  it "restart resets the Int64 counter" do
    spray = Widget::Effect::Spray.new width: 6, height: 3
    spray.resize 6, 3
    20.times { spray.advance 6, 3 }
    spray.restart
    # A fresh frame-0 advance must not raise.
    spray.advance 6, 3
  end
end

describe "BUGS14 A5: HeatMap tolerates a non-finite explicit color-scale bound" do
  it "does not raise on render when vmin is Infinity" do
    s = bugs14_screen
    hm = Widget::Graph::HeatMap.new parent: s, top: 0, left: 0, width: 24, height: 10,
      data: [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
    hm.vmin = Float64::INFINITY
    # resolved_bounds must fall back to the finite data range.
    lo, hi = hm.value_range
    lo.finite?.should be_true
    hi.finite?.should be_true
    hi.should be > lo
    s._render
  ensure
    s.try &.destroy
  end

  it "does not raise when vmax is NaN" do
    s = bugs14_screen
    hm = Widget::Graph::HeatMap.new parent: s, top: 0, left: 0, width: 24, height: 10,
      data: [[10.0, 20.0], [30.0, 40.0]]
    hm.vmax = Float64::NAN
    lo, hi = hm.value_range
    lo.finite?.should be_true
    hi.finite?.should be_true
    s._render
  ensure
    s.try &.destroy
  end

  it "color_for returns a valid LUT color even with a poisoned bound" do
    hm = Widget::Graph::HeatMap.new width: 24, height: 10,
      data: [[1.0, 2.0], [3.0, 4.0]]
    hm.vmin = Float64::INFINITY
    hm.vmax = Float64::INFINITY
    # Both bounds non-finite: color_for must not raise and must return a color.
    c = hm.color_for 2.5
    c.should be >= 0
  end

  it "still honors a finite explicit bound (no regression)" do
    hm = Widget::Graph::HeatMap.new width: 24, height: 10,
      data: [[1.0, 2.0], [3.0, 4.0]]
    hm.vmin = 0.0
    hm.vmax = 10.0
    lo, hi = hm.value_range
    lo.should eq 0.0
    hi.should eq 10.0
  end
end
