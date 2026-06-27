require "./spec_helper"

include Crysterm

# Focused specs for CSS color properties (`Crysterm::CSS::Properties.apply`).
# The interesting case — as with `z-index`/`visibility`/`display` (see their
# specs) — is the *blank* value: a `var(--x)` whose custom property is undefined
# collapses to "" before reaching the property. Per CSS such an invalid
# declaration is dropped, leaving any previously-cascaded color intact; it must
# NOT clobber the color to the terminal default (`-1`), which would silently
# reset a color a lower-priority rule had set (e.g. the theme's
# `Box { background-color: var(--surface) }`).
describe "CSS color (invalid value)" do
  it "parses a valid color" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "color", "#ff0000")
    s.fg.should eq 0xff0000
    Crysterm::CSS::Properties.apply(s, "background-color", "#00ff00")
    s.bg.should eq 0x00ff00
  end

  it "drops a blank `color`, keeping a previously-set foreground" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "color", "#123456")
    # An undefined `var()` collapses to "" before reaching the property — must
    # not reset fg to the terminal default (-1).
    Crysterm::CSS::Properties.apply(s, "color", "")
    s.fg.should eq 0x123456
  end

  it "drops a blank `background-color`, keeping a previously-set background" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-color", "#abcdef")
    Crysterm::CSS::Properties.apply(s, "background-color", "   ")
    s.bg.should eq 0xabcdef
  end

  it "still honors `transparent` (a genuine terminal-default color)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-color", "#abcdef")
    Crysterm::CSS::Properties.apply(s, "background-color", "transparent")
    s.bg.should eq -1
  end

  it "drops a blank `border-color`, keeping the previously-set border color" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-color", "#0000ff")
    Crysterm::CSS::Properties.apply(s, "border-color", "")
    s.border.fg.should eq 0x0000ff
  end

  it "drops a blank per-side `border-top-color`, leaving the side unset" do
    s = Style.new
    # With no per-side override the side falls back to the whole-border color.
    Crysterm::CSS::Properties.apply(s, "border-color", "#0000ff")
    Crysterm::CSS::Properties.apply(s, "border-top-color", "")
    s.border.fg_top.should be_nil
    s.border.top_fg.should eq 0x0000ff
  end
end
