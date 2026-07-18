require "./spec_helper"

include Crysterm

# A malformed color *function* is an invalid declaration and must be dropped,
# keeping any previously-cascaded color rather than clobbering it to unset.
# Realistic trigger: `color: rgb(var(--x), 0, 0)` with `--x` undefined
# resolves to `rgb(, 0, 0)`, which no longer parses, so per CSS the whole
# declaration is dropped. Distinct from `inherit`/`initial`/`unset`/
# `currentColor`, which still reset so inheritance can refill them.
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
    s.border.top_fg.should eq 0x00ff00
  end

  it "still applies a valid `rgb()` color" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "color", "rgb(255, 0, 0)")
    s.fg.should eq 0xff0000
  end
end
