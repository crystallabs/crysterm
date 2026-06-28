require "./spec_helper"

include Crysterm

# A malformed color *function* is an invalid declaration and, like a blank
# value, must be dropped — leaving any previously-cascaded color intact rather
# than clobbering it to unset. The realistic trigger is an undefined `var()`
# inside a color function: `color: rgb(var(--x), 0, 0)` with `--x` undefined is
# resolved by the cascade to `rgb(, 0, 0)` (the `var()` collapses to "") before
# reaching `Properties.apply` — that no longer parses to a color, so per CSS the
# whole declaration is dropped. (Distinct from the genuine-unset keyword forms
# `inherit`/`initial`/`unset`/`currentColor`, which still reset so inheritance
# can refill them.)
describe "CSS color (malformed function value)" do
  it "drops a malformed `rgb()` color, keeping a previously-set foreground" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "color", "#123456")
    Crysterm::CSS::Properties.apply(s, "color", "rgb(, 0, 0)")
    s.fg.should eq 0x123456
  end

  it "drops a malformed `hsl()` background-color, keeping a previous background" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-color", "#abcdef")
    Crysterm::CSS::Properties.apply(s, "background-color", "hsl(, ,)")
    s.bg.should eq 0xabcdef
  end

  it "drops a malformed per-side `border-top-color`, keeping the prior side color" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-top-color", "#00ff00")
    Crysterm::CSS::Properties.apply(s, "border-top-color", "rgb(255)")
    s.border.fg_top.should eq 0x00ff00
  end

  it "still applies a valid `rgb()` color" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "color", "rgb(255, 0, 0)")
    s.fg.should eq 0xff0000
  end
end
