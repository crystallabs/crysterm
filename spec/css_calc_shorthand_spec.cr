require "./spec_helper"

include Crysterm

# Focused specs for `calc(...)` inside the multi-value numeric shorthands
# (`padding`/`margin`/`border-width`). CSS *requires* whitespace around the
# `+`/`-` operators in `calc()` (`calc(2em + 1em)` is the only spec-valid
# spelling — `calc(2em+1em)` is invalid), so the shorthand parsers must keep a
# space-bearing `calc()` together as a single token. They split with
# `split_top_level` (paren-aware), exactly like the color shorthands; a plain
# `value.split` would shred `calc(2em + 1em)` into `calc(2em`/`+`/`1em)` — three
# bogus "sides" — and silently mis-apply the declaration.
#
# `em` is used throughout: its divisor is `1.0` and isotropic (not scaled by the
# cell aspect ratio), so `1em == 1 cell` on both axes regardless of terminal.
describe "CSS calc() in numeric shorthands" do
  it "keeps a space-bearing calc() as one padding value (all sides)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "padding", "calc(2em + 1em)")
    s.padding.left.should eq 3
    s.padding.top.should eq 3
    s.padding.right.should eq 3
    s.padding.bottom.should eq 3
  end

  it "keeps a space-bearing calc() as one token in a 2-value padding shorthand" do
    s = Style.new
    # vertical horizontal: vertical = calc(1em + 1em) = 2, horizontal = 5.
    Crysterm::CSS::Properties.apply(s, "padding", "calc(1em + 1em) 5")
    s.padding.top.should eq 2
    s.padding.bottom.should eq 2
    s.padding.left.should eq 5
    s.padding.right.should eq 5
  end

  it "keeps a space-bearing calc() as one margin value (all sides)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "margin", "calc(2em + 1em)")
    s.margin.left.should eq 3
    s.margin.top.should eq 3
    s.margin.right.should eq 3
    s.margin.bottom.should eq 3
  end

  it "keeps a space-bearing calc() as one border-width value (all sides)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-width", "calc(2em + 1em)")
    s.border.left.should eq 3
    s.border.top.should eq 3
    s.border.right.should eq 3
    s.border.bottom.should eq 3
  end
end
