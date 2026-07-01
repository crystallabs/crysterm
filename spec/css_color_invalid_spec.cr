require "./spec_helper"

include Crysterm

# Focused specs for CSS color properties (`Crysterm::CSS::Properties.apply`).
# As with `z-index`/`visibility`/`display` (see their specs), the interesting
# case is a blank value: an undefined `var(--x)` collapses to "" before
# reaching the property. Per CSS this invalid declaration is dropped, leaving
# any previously-cascaded color intact — it must not clobber to the terminal
# default (`-1`).
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
    # An undefined `var()` collapses to "" — must not reset fg to -1.
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
    # No per-side override -> falls back to the whole-border color.
    Crysterm::CSS::Properties.apply(s, "border-color", "#0000ff")
    Crysterm::CSS::Properties.apply(s, "border-top-color", "")
    s.border.fg_top.should be_nil
    s.border.top_fg.should eq 0x0000ff
  end
end
