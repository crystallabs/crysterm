require "./spec_helper"

include Crysterm

# Behavior lock for `Easing#apply` (the pure `Float64 -> Float64` curve mapper
# under `FrameClock` tweens and the CSS `transition`/`animation` timing
# keywords). No clock or terminal needed — it's plain math.
describe "Easing#apply" do
  all = [
    Easing::Linear, Easing::InQuad, Easing::OutQuad, Easing::InOutQuad,
    Easing::InCubic, Easing::OutCubic, Easing::InOutCubic, Easing::InOutSine,
  ]

  it "pins the endpoints to 0.0 and 1.0 for every curve" do
    all.each do |e|
      e.apply(0.0).should be_close(0.0, 1e-12)
      e.apply(1.0).should be_close(1.0, 1e-12)
    end
  end

  it "computes the known midpoints" do
    Easing::Linear.apply(0.5).should be_close(0.5, 1e-12)
    Easing::InQuad.apply(0.5).should be_close(0.25, 1e-12)
    Easing::OutQuad.apply(0.5).should be_close(0.75, 1e-12)
    Easing::InOutQuad.apply(0.5).should be_close(0.5, 1e-12)
    Easing::InCubic.apply(0.5).should be_close(0.125, 1e-12)
    Easing::OutCubic.apply(0.5).should be_close(0.875, 1e-12)
    Easing::InOutCubic.apply(0.5).should be_close(0.5, 1e-12)
    Easing::InOutSine.apply(0.5).should be_close(0.5, 1e-12)
  end

  it "computes representative sub-midpoint values from the piecewise branches" do
    # The `t < 0.5` branch of each InOut curve.
    Easing::InOutQuad.apply(0.25).should be_close(0.125, 1e-12)   # 2 * 0.25^2
    Easing::InOutCubic.apply(0.25).should be_close(0.0625, 1e-12) # 4 * 0.25^3
    # And a `t >= 0.5` sample.
    Easing::InOutQuad.apply(0.75).should be_close(0.875, 1e-12) # 1 - (-1.5+2)^2/2
    Easing::Linear.apply(0.3).should be_close(0.3, 1e-12)       # identity
  end

  it "is monotonically non-decreasing across the domain for every curve" do
    ts = (0..20).map { |i| i / 20.0 }
    all.each do |e|
      prev = e.apply(ts.first)
      ts.each do |t|
        v = e.apply(t)
        v.should be >= (prev - 1e-12)
        prev = v
      end
    end
  end

  it "keeps `In` below and `Out` above the linear line before the midpoint" do
    # An accelerating (In) curve lags identity; a decelerating (Out) leads it.
    t = 0.3
    Easing::InQuad.apply(t).should be < t
    Easing::OutQuad.apply(t).should be > t
    Easing::InCubic.apply(t).should be < t
    Easing::OutCubic.apply(t).should be > t
  end
end
