require "./spec_helper"

include Crysterm

# Focused spec for `Crysterm::CSS::ColorValue.resolve` with `hsl()` hues that
# carry a CSS angle *unit*.
#
# The hue of `hsl()` is a CSS `<angle>`, so it may be written with `deg`, `grad`,
# `rad` or `turn` (a bare number is degrees). The parser used to read *every*
# hue as degrees, ignoring the unit — so `hsl(0.5turn, …)` (180°, cyan) resolved
# to 0.5° (red), and `200grad`/`π rad` (also 180°) were likewise mis-read. The
# unit is now converted to degrees before the wrap, mirroring how the sibling
# `rgb()` parser was fixed to honor its signed channels.
describe "Crysterm::CSS::ColorValue hsl() angle units" do
  cyan = (0 << 16) | (255 << 8) | 255 # hsl(180, 100%, 50%)

  it "reads `turn` as a full revolution (0.5turn == 180deg)" do
    Crysterm::CSS::ColorValue.resolve("hsl(0.5turn, 100%, 50%)", nil).should eq cyan
  end

  it "reads `grad` (400grad == 360deg, so 200grad == 180deg)" do
    Crysterm::CSS::ColorValue.resolve("hsl(200grad, 100%, 50%)", nil).should eq cyan
  end

  it "reads `rad` (π rad == 180deg)" do
    Crysterm::CSS::ColorValue.resolve("hsl(3.14159265rad, 100%, 50%)", nil).should eq cyan
  end

  it "wraps a full turn back to 0 (1turn == 360deg == 0deg, red)" do
    Crysterm::CSS::ColorValue.resolve("hsl(1turn, 100%, 50%)", nil).should eq 0xff0000
  end

  it "folds the unit's case (`0.5TURN` == `0.5turn`)" do
    Crysterm::CSS::ColorValue.resolve("hsla(0.5TURN, 100%, 50%, 0.5)", nil).should eq cyan
  end

  it "still reads a bare number and explicit `deg` as degrees" do
    Crysterm::CSS::ColorValue.resolve("hsl(180, 100%, 50%)", nil).should eq cyan
    Crysterm::CSS::ColorValue.resolve("hsl(180deg, 100%, 50%)", nil).should eq cyan
  end

  it "still wraps a negative degree hue (-120 == 240, blue)" do
    Crysterm::CSS::ColorValue.resolve("hsl(-120, 100%, 50%)", nil).should eq 0x0000ff
  end
end
