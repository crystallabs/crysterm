require "./spec_helper"

include Crysterm

# The whole-`border` shorthand must resolve its color token through `ColorValue`
# like the `border-color` longhand and `border-<side>` shorthand, so
# `currentColor` and color functions (`rgb()`/`hsl()`) work and a function's
# internal spaces/commas survive tokenization.
# (`Crysterm::CSS::Properties.apply`, `border` shorthand → `parse_border`.)
#
# Regression: `parse_border` used to split on whitespace and assign the raw
# token straight to `Border#fg`, so `border: solid rgb(255,0,0)` was torn into
# `rgb(255,`/`0,`/`0)` (each an unknown sentinel), and `currentColor` resolved
# to garbage instead of the text color.
describe "CSS border shorthand color" do
  it "resolves an rgb() color with internal spaces/commas" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border", "solid rgb(255, 0, 0)")
    s.border.fg.should eq 0xff0000
    s.border.type.should eq BorderType::Solid
  end

  it "resolves an hsl() color in the shorthand" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border", "1em solid hsl(120, 100%, 50%)")
    s.border.fg.should eq 0x00ff00 # pure green
  end

  it "resolves currentColor to the element text color" do
    s = Style.new(fg: 0x0000ff) # blue text
    Crysterm::CSS::Properties.apply(s, "border", "solid currentColor")
    s.border.fg.should eq 0x0000ff
  end

  it "still accepts a plain named/hex color" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border", "solid #abcdef")
    s.border.fg.should eq 0xabcdef
  end

  it "leaves the border uncolored when no color token is present" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border", "solid")
    s.border.fg.should be_nil
  end
end
