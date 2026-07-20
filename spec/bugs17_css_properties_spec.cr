require "./spec_helper"

include Crysterm

# Regression specs for BUGS17 CSS property-parser fixes (all in
# `src/style/css/properties.cr`, via `Crysterm::CSS::Properties.apply`):
#
#  * B17-12 — the `animation` shorthand tokenized with a plain `value.split`, so a
#    comma-bearing timing function (`cubic-bezier(0.4, 0, 0.2, 1)`, `steps(2,
#    start)`) shredded into fragments that hijacked the keyframes name (name
#    became "1)" / "start)"), silently killing the animation.
#  * B17-13 — the `border-<side>-color` longhand and `border-<side>` shorthand
#    stored the `-1` unknown-color sentinel (and the shorthand a malformed-function
#    `nil`) instead of dropping the invalid token and keeping the prior color.
#  * B17-14 — the `border-width` shorthand zeroed the affected sides for an
#    unparseable token instead of dropping the whole declaration.
#  * B17-15 — the `border` shorthand stored negative side widths (e.g. from a
#    negative calc()) instead of clamping them to 0.
describe "CSS animation shorthand (paren-aware tokenizing) — B17-12" do
  it "keeps the keyframes name past a comma-bearing cubic-bezier easing" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "animation", "spin 2s cubic-bezier(0.4, 0, 0.2, 1) infinite")
    spec = s.animation.not_nil!
    spec.name.should eq "spin"
    spec.duration.should eq 2.seconds
    spec.iterations.should be_nil # infinite
  end

  it "keeps the keyframes name past a comma-bearing steps() easing" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "animation", "blink 1s steps(2, start) infinite")
    spec = s.animation.not_nil!
    spec.name.should eq "blink"
  end
end

describe "CSS per-side border color invalid-token handling — B17-13" do
  it "drops an unknown border-top-color name, leaving the slot untouched" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-top-color", "bleu")
    s.border.@top_fg.should be_nil
    s.border.top_fg.should be_nil
  end

  it "keeps a prior border-top-color when a later unknown name is applied" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-top-color", "red")
    Crysterm::CSS::Properties.apply(s, "border-top-color", "bleu")
    s.border.@top_fg.should eq Colors.convert_cached("red")
    s.border.top_fg.should eq Colors.convert_cached("red")
  end

  it "keeps a prior per-side color when `border-<side>` carries an unknown name" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-left-color", "red")
    Crysterm::CSS::Properties.apply(s, "border-left", "solid bleu")
    s.border.@left_fg.should eq Colors.convert_cached("red")
    s.border.left_fg.should eq Colors.convert_cached("red")
  end
end

describe "CSS border-width shorthand invalid-token handling — B17-14" do
  it "drops the whole declaration on a typo'd named width, keeping the prior border" do
    s = Style.new
    s.border = Crysterm::Border.new(left: 4, top: 4, right: 4, bottom: 4)
    Crysterm::CSS::Properties.apply(s, "border-width", "1px thinn")
    s.border.top.should eq 4
    s.border.right.should eq 4
    s.border.bottom.should eq 4
    s.border.left.should eq 4
  end
end

describe "CSS border shorthand negative-width clamping — B17-15" do
  it "clamps a negative calc() width to 0 on all sides" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border", "calc(1em - 2em) solid")
    s.border.top.should eq 0
    s.border.right.should eq 0
    s.border.bottom.should eq 0
    s.border.left.should eq 0
  end
end
