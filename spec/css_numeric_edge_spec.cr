require "./spec_helper"

include Crysterm

# Numeric edge cases in CSS value parsing that must clamp/fold rather than raise.

# `rgb()` channels far outside 0..255 must clamp to 255, not overflow Int32 and
# raise in the float→int conversion. The clamp used to convert to Int32 *before*
# clamping, so a channel like `99999999999` raised `OverflowError` mid-cascade.
describe "Crysterm::CSS::ColorValue rgb() out-of-range channel" do
  it "clamps a huge positive channel to 255 without raising" do
    Crysterm::CSS::ColorValue.resolve("rgb(99999999999, 0, 0)", nil)
      .should eq (255 << 16) | (0 << 8) | 0
  end

  it "clamps a huge negative channel to 0 without raising" do
    Crysterm::CSS::ColorValue.resolve("rgb(-99999999999, 20, 30)", nil)
      .should eq (0 << 16) | (20 << 8) | 30
  end

  it "clamps a huge percentage channel to 255 without raising" do
    Crysterm::CSS::ColorValue.resolve("rgb(50000000000%, 0%, 0%)", nil)
      .should eq (255 << 16) | (0 << 8) | 0
  end

  it "still resolves ordinary channels unchanged" do
    Crysterm::CSS::ColorValue.resolve("rgb(10, 20, 30)", nil)
      .should eq (10 << 16) | (20 << 8) | 30
  end
end

# CSS keyframe selectors `from`/`to` are keywords, hence case-insensitive.
describe "Crysterm::CSS::Stylesheet @keyframes selector case" do
  it "reads case-folded `From`/`TO` keyframe selectors" do
    sheet = Crysterm::CSS::Stylesheet.parse(<<-CSS)
      @keyframes fade { From { color: red; } TO { color: blue; } }
      CSS
    stops = sheet.keyframes_for("fade", 80, 24, 256).not_nil!
    stops.map(&.[0]).should eq [0.0, 1.0]
  end

  it "agrees with the lowercase spelling" do
    up = Crysterm::CSS::Stylesheet.parse("@keyframes a { From { color: red; } }")
    lo = Crysterm::CSS::Stylesheet.parse("@keyframes a { from { color: red; } }")
    up.keyframes_for("a", 80, 24, 256).not_nil!.map(&.[0])
      .should eq lo.keyframes_for("a", 80, 24, 256).not_nil!.map(&.[0])
  end
end
