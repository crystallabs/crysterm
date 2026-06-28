require "./spec_helper"

include Crysterm

# The whole-`border` shorthand must resolve its color token through `ColorValue`
# exactly like the `border-color` longhand and the `border-<side>` shorthand —
# so `currentColor` and the color *functions* (`rgb()`/`hsl()`) work, and a
# function's internal spaces/commas aren't shredded by tokenization.
# (`Crysterm::CSS::Properties.apply`, the `border` shorthand → `parse_border`.)
#
# Previously `parse_border` split on plain whitespace and assigned the raw token
# straight to `Border#fg`, bypassing resolution: `border: solid rgb(255,0,0)`
# was torn into `rgb(255,`/`0,`/`0)` (each → the `-1` unknown sentinel), and
# `border: solid currentColor` resolved to garbage instead of the text color.
describe "CSS border shorthand color" do
  it "resolves an rgb() color with internal spaces/commas" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border", "solid rgb(255, 0, 0)")
    s.border.fg.should eq 0xff0000
    s.border.type.should eq BorderType::Line
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
