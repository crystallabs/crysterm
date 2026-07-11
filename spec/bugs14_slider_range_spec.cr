require "./spec_helper"

include Crysterm

# BUGS14 A1 / A2 / M1 / M3 — Int32-overflow guards on large-range
# slider / progressbar / ranged-value math.
#
# All four defects multiplied or subtracted two Int32 quantities before the
# float divide (or accumulated a step counter in Int32 across the value range),
# so a range span above ~Int32::MAX overflowed and raised OverflowError during a
# render, a track click/drag, or a percentage set. The fixes widen/float-coerce
# the arithmetic and clamp, and iterate ticks over track cells rather than value
# space.

private def range_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Exposes the protected pointer->value mapping so the off-track case (which the
# window's hit-testing never delivers to an out-of-bounds pointer) can be driven
# directly, exactly as `Slider`'s drag handler feeds it a raw, unclamped offset.
private class ExposedSlider < Widget::Slider
  def value_at_pub(pos : Int32, span : Int32) : Int32
    value_at pos, span
  end
end

describe "BUGS14 large-range slider/progressbar overflow guards" do
  # A2 — Mixin::RangedValue#value_span computed `@maximum - @minimum` in Int32,
  # overflowing for any range wider than Int32::MAX.
  it "computes value_span for a full Int32-span range without overflowing (A2)" do
    s = range_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 60, height: 1,
      minimum: Int32::MIN, maximum: Int32::MAX
    # `@maximum - @minimum` (== 2**32 - 1) overflowed Int32 here; the fix widens
    # the subtraction and clamps back to Int32::MAX.
    sl.value_span.should eq Int32::MAX
  end

  # A1 — AbstractSlider#value_at raised OverflowError on an off-track drag with a
  # large value range (Slider passes the raw, unclamped pointer offset).
  it "maps an off-track offset on a narrow large-range Slider without overflowing (A1)" do
    s = range_screen
    sl = ExposedSlider.new parent: s, top: 0, left: 0, width: 11, height: 1,
      minimum: 0, maximum: 300_000_000, value: 0
    # An offset far past the track end (pos 110, span 10) with a large range made
    # `pos.to_f * value_span / span` (3.3e9) exceed Int32::MAX so `.round.to_i`
    # raised OverflowError. The fix clamps into the value span -> the maximum
    # (exactly what `#value=` would clamp an off-track pointer to).
    sl.value_at_pub(110, 10).should eq 300_000_000
  end

  # M1 — ProgressBar#filled= evaluated `percent * span` as Int32 × Int32 before
  # the `/ 100.0`, overflowing for a span above ~21M.
  it "sets ProgressBar#filled on a large-range bar without raising (M1)" do
    s = range_screen
    # `bar.filled = 50` runs during construction here; `50 * 50_000_000` (Int32)
    # overflowed. The fix coerces to Float64 before multiplying.
    bar = Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 40, height: 1,
      minimum: 0, maximum: 50_000_000, filled: 50
    bar.filled.should eq 50
    bar.value.should eq 25_000_000
    bar.filled = 100 # must not raise OverflowError
    bar.value.should eq 50_000_000
  end

  # M1 (span) — ProgressBar#span subtracted `@maximum - @minimum` in Int32,
  # overflowing for a range wider than Int32::MAX. #filled derives from #span.
  it "derives ProgressBar#filled across an Int32-wide range without raising (M1 span)" do
    s = range_screen
    bar = Widget::ProgressBar.new parent: s, top: 0, left: 0, width: 40, height: 1,
      minimum: -1_500_000_000, maximum: 1_500_000_000, value: 0
    # `@maximum - @minimum` (== 3e9) overflowed Int32 in #span; the fix widens the
    # subtraction and clamps to Int32::MAX, so a range wider than Int32::MAX yields
    # a valid (approximate) percentage instead of crashing.
    bar.filled.should be >= 0
    bar.filled.should be <= 100
    bar.filled = 25 # must not raise OverflowError
    bar.value.should be < 0
  end

  # M3 — Slider tick rendering iterated over value-space one step at a time,
  # hanging for large ranges and overflowing the `tv += interval` counter when
  # `@maximum` sat within `interval` of Int32::MAX.
  it "renders ticks on a Slider whose maximum is near Int32::MAX without hanging/raising (M3)" do
    s = range_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 60, height: 3,
      minimum: 0, maximum: Int32::MAX, value: 1_000_000,
      tick_position: Widget::Slider::TickPosition::Both
    s._render # value-space loop would run ~2e8 iterations and overflow on the add
    sl.value.should eq 1_000_000
  end

  # M3 — same guard on the vertical tick path.
  it "renders a vertical large-range Slider with ticks without raising (M3 vertical)" do
    s = range_screen
    sl = Widget::Slider.new parent: s, top: 0, left: 0, width: 3, height: 20,
      orientation: Tput::Orientation::Vertical,
      minimum: 0, maximum: Int32::MAX, value: 2_000_000_000,
      tick_position: Widget::Slider::TickPosition::Both
    s._render
    sl.value.should eq 2_000_000_000
  end
end
