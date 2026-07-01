require "./spec_helper"

include Crysterm

# The `border-color` shorthand recolors the whole border, so it must also clear
# any per-side override (`border-top-color` & co.) a prior declaration set.
# `Border#top_fg` & co. resolve to `@fg_<side> || @fg`; without the reset a
# stale per-side color shadows the new color, leaving e.g.
# `border-top-color: red; border-color: blue` red on top (a browser paints all
# four sides blue).
describe "CSS border-color shorthand reset" do
  it "overrides a per-side color set by an earlier declaration" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-top-color", "#ff0000")
    Crysterm::CSS::Properties.apply(s, "border-color", "#0000ff")
    b = s.border
    # Per-side override cleared; every side resolves to the new color.
    b.fg_top.should be_nil
    b.top_fg.should eq 0x0000ff
    b.right_fg.should eq 0x0000ff
    b.bottom_fg.should eq 0x0000ff
    b.left_fg.should eq 0x0000ff
    b.fg.should eq 0x0000ff
  end

  it "still lets a later per-side longhand re-override (declaration order wins)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-color", "#0000ff")
    Crysterm::CSS::Properties.apply(s, "border-top-color", "#ff0000")
    b = s.border
    b.top_fg.should eq 0xff0000   # top re-overridden after the shorthand
    b.right_fg.should eq 0x0000ff # others keep the whole-border color
    b.fg.should eq 0x0000ff
  end

  it "drops a blank value (invalid declaration) without resetting per-side colors" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-top-color", "#ff0000")
    Crysterm::CSS::Properties.apply(s, "border-color", "") # e.g. undefined var() collapsed to ""
    s.border.fg_top.should eq 0xff0000
  end
end
