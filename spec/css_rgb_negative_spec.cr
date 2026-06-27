require "./spec_helper"

include Crysterm

# Focused spec for `Crysterm::CSS::ColorValue.resolve` with out-of-range `rgb()` channels.
#
# CSS clamps an out-of-range color channel into `0..255`, so a *negative*
# channel resolves to `0`. The per-channel regex used to omit the sign, which
# made `rgb(-10, …)` silently parse as `rgb(10, …)` — reading the magnitude
# instead of the (clamped-to-zero) negative. The sibling `hsl()` parser already
# carried a signed pattern for exactly this reason; `rgb()` now matches.
describe "Crysterm::CSS::ColorValue rgb() negative channel" do
  it "clamps a negative channel to 0 rather than reading its magnitude" do
    # red is negative -> 0; green/blue pass through.
    Crysterm::CSS::ColorValue.resolve("rgb(-10, 20, 30)", nil).should eq (0 << 16) | (20 << 8) | 30
  end

  it "clamps every negative channel independently" do
    Crysterm::CSS::ColorValue.resolve("rgb(-5, -200, 40)", nil).should eq (0 << 16) | (0 << 8) | 40
  end

  it "still parses ordinary positive channels unchanged" do
    Crysterm::CSS::ColorValue.resolve("rgb(10, 20, 30)", nil).should eq (10 << 16) | (20 << 8) | 30
  end

  it "clamps a negative percentage channel to 0" do
    Crysterm::CSS::ColorValue.resolve("rgb(-50%, 100%, 0%)", nil).should eq (0 << 16) | (255 << 8) | 0
  end
end
