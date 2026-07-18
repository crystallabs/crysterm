require "./spec_helper"

include Crysterm

# Per CSS, `currentColor` in a border color must resolve to the element's text
# color (`color` / `Style#fg`), not the border's own existing color
# (`Crysterm::CSS::Properties.apply`).
#
# The old code threaded `border.fg` as the `currentColor` basis, so
# `border-color: currentColor` resolved to whatever the border was already
# colored (usually unset) instead of the text color.
describe "CSS border currentColor" do
  it "resolves the border-color shorthand to the element text color" do
    s = Style.new(fg: 0xff0000) # red text
    Crysterm::CSS::Properties.apply(s, "border-style", "solid")
    Crysterm::CSS::Properties.apply(s, "border-color", "currentColor")
    s.border.fg.should eq 0xff0000
  end

  it "resolves a per-side border-*-color longhand to the element text color" do
    s = Style.new(fg: 0x00ff00) # green text
    Crysterm::CSS::Properties.apply(s, "border-top-color", "currentColor")
    s.border.top_fg.should eq 0x00ff00
    s.border.top_fg.should eq 0x00ff00
  end

  it "resolves the per-side border-<side> shorthand color to the element text color" do
    s = Style.new(fg: 0x0000ff) # blue text
    Crysterm::CSS::Properties.apply(s, "border-left", "solid currentColor")
    s.border.left_fg.should eq 0x0000ff
    s.border.left_fg.should eq 0x0000ff
  end

  it "leaves a concrete color unaffected (currentColor basis is unused there)" do
    s = Style.new(fg: 0xff0000)
    Crysterm::CSS::Properties.apply(s, "border-color", "#abcdef")
    s.border.fg.should eq 0xabcdef
  end
end
