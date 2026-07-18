require "./spec_helper"

include Crysterm

# Regression specs for the BUGS7 animation fixes.
#
# 1. `apply_keyframe` must clamp the interpolation fraction to `[0,1]`: keyframes
#    that don't span `0%..100%` (e.g. `from{0.2} 50%{1.0}` with no `100%`) would
#    otherwise extrapolate opacity past `[0,1]` for progress beyond the last stop.
#
# 2. `pulse` drives its phase from real wall-clock elapsed, so the eased breathe
#    stays within `[min, max]` and advances with time.

private def anim_window(w = 10, h = 3)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "BUGS7 @keyframes opacity clamp for partial-range stops" do
  it "never extrapolates alpha above 1.0 when no 100% stop is declared" do
    s = anim_window
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.add_css_class "partial"
    # No `100%` stop: progress past 0.5 would extrapolate `t > 1` -> alpha > 1.0
    # without the clamp.
    s.stylesheet = "@keyframes partial { from { opacity: 0.2; } 50% { opacity: 1.0; } } " \
                   ".partial { opacity: 0.2; animation: partial 0.2s linear infinite; }"
    s._render # starts the animation

    max_seen = 0.0
    min_seen = 1.0
    12.times do
      sleep 0.03.seconds
      a = b.style.opacity.not_nil!
      max_seen = a if a > max_seen
      min_seen = a if a < min_seen
    end
    (max_seen <= 1.0 + 1e-9).should be_true # clamped, never extrapolated up
    (min_seen >= 0.0 - 1e-9).should be_true
  ensure
    s.try &.destroy
  end
end

describe "BUGS7 pulse breathe stays within [min, max]" do
  it "keeps the eased alpha bounded and advancing over time" do
    s = anim_window
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 3
    b.pulse min: 0.3, max: 1.0, period: 0.12.seconds

    samples = [] of Float64
    10.times do
      sleep 0.03.seconds
      a = b.style.opacity.not_nil!
      (0.3 - 1e-9 <= a <= 1.0 + 1e-9).should be_true
      samples << a
    end
    # It actually moved (not frozen): more than one distinct value across the run.
    samples.uniq.size.should be > 1
  ensure
    b.try &.stop_fade
    s.try &.destroy
  end
end
