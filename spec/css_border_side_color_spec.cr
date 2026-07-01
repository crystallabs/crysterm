require "./spec_helper"

include Crysterm

# Focused specs for `border-<side>` shorthand color (`Crysterm::CSS::Properties.apply`).
#
# The renderer paints each border edge from its per-side color
# (`Border#top_fg`/`#left_fg`/…, falling back to the whole-border `#fg`); the
# `border-<side>-color` longhand already routes to that per-side slot, and the
# `border-<side>` shorthand must too: `border-left: solid red` colors only the
# left edge, not the whole border.
describe "CSS border-<side> shorthand color" do
  it "colors only the named side, leaving the others on the whole-border color" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-color", "#0000ff") # whole-border blue
    Crysterm::CSS::Properties.apply(s, "border-left", "solid #ff0000")
    b = s.border
    # Left edge takes the per-side override; others fall back to blue.
    b.fg_left.should eq 0xff0000
    b.left_fg.should eq 0xff0000
    b.fg_top.should be_nil
    b.top_fg.should eq 0x0000ff
    b.right_fg.should eq 0x0000ff
    b.bottom_fg.should eq 0x0000ff
    # The whole-border color is untouched by the per-side shorthand.
    b.fg.should eq 0x0000ff
  end

  it "matches the border-<side>-color longhand routing (per-side, not whole)" do
    shorthand = Style.new
    Crysterm::CSS::Properties.apply(shorthand, "border-top", "solid #00ff00")

    longhand = Style.new
    Crysterm::CSS::Properties.apply(longhand, "border-top-color", "#00ff00")

    shorthand.border.fg_top.should eq longhand.border.fg_top
    shorthand.border.fg_top.should eq 0x00ff00
    # Neither touches the whole-border color.
    shorthand.border.fg.should be_nil
  end

  it "still sets the side's width/type from the same shorthand" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-right", "2 dashed #abcdef")
    s.border.right.should eq 2
    s.border.type.should eq BorderType::Dashed
    s.border.fg_right.should eq 0xabcdef
  end
end
