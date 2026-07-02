require "./spec_helper"

include Crysterm

# Regression specs for the BUGS7 "CSS Engine" fixes.
#
# 1. A comma in an `@media` prelude is a logical OR of full queries, not an AND
#    of feature groups. `(max-width: 40), (min-width: 100)` must match a narrow
#    *or* a wide terminal; before the fix every group was AND-ed, so such a list
#    matched nothing.
#
# 2. `!important` may carry interior whitespace (`red ! important`); the spaced
#    form was mis-parsed as a normal declaration with a bogus value.
#
# 3. Pseudo-class/element names are case-insensitive: `:CHECKED`, `::SLOT` and
#    `:HAS(...)` must lower like their lowercase forms, not silently drop the
#    rule.

private def parse(css : String)
  Crysterm::CSS::Stylesheet.parse(css)
end

describe "BUGS7 @media comma is OR, not AND" do
  it "matches when either comma-separated query holds" do
    q = Crysterm::CSS::MediaQuery.parse("(max-width: 40), (min-width: 100)")
    q.matches?(30, 24, 256).should be_true  # narrow → first query
    q.matches?(120, 24, 256).should be_true # wide → second query
    q.matches?(60, 24, 256).should be_false # neither
  end

  it "collapses an overlapping OR to its looser bound" do
    q = Crysterm::CSS::MediaQuery.parse("(min-width: 40), (min-width: 100)")
    q.matches?(50, 24, 256).should be_true # satisfies the >= 40 query
  end

  it "still ANDs feature groups within one query" do
    q = Crysterm::CSS::MediaQuery.parse("(min-width: 20) and (max-width: 40)")
    q.matches?(30, 24, 256).should be_true
    q.matches?(50, 24, 256).should be_false # width above the AND range
  end

  it "OR-matches an unmatchable group away (one bad group doesn't poison the list)" do
    # `print` is unmatchable, but the width query still applies.
    q = Crysterm::CSS::MediaQuery.parse("print, (min-width: 80)")
    q.matches?(100, 24, 256).should be_true
    q.matches?(40, 24, 256).should be_false
  end
end

describe "BUGS7 !important with interior whitespace" do
  it "recognizes a spaced `! important` and strips it into the important bucket" do
    rule = parse("Box { color: red ! important; }").rules.first
    rule.important.has_key?("color").should be_true
    rule.important["color"].should eq "red"
    rule.declarations.has_key?("color").should be_false
  end

  it "still handles the no-space and uppercase forms" do
    parse("Box { color: red!important; }").rules.first.important["color"].should eq "red"
    parse("Box { color: red !IMPORTANT; }").rules.first.important["color"].should eq "red"
  end
end

describe "BUGS7 case-insensitive pseudo rewrites" do
  it "lowers an uppercase attribute pseudo `:CHECKED` like `:checked`" do
    upper = parse "CheckBox:CHECKED { color: red; }"
    lower = parse "CheckBox:checked { color: red; }"
    # Both rewrite `:checked` to the `[checked]` attribute selector.
    upper.rules.first.selector.should eq lower.rules.first.selector
    upper.rules.first.selector.should contain "[checked]"
  end

  it "lowers a mixed-case sub-element pseudo `::SLOT` like `::slot`" do
    upper = parse "ProgressBar::INDICATOR { color: red; }"
    lower = parse "ProgressBar::indicator { color: red; }"
    upper.rules.first.selector.should eq lower.rules.first.selector
  end

  it "peels an uppercase `:HAS(...)` the same as `:has(...)`" do
    upper = parse "Box:HAS(.error) { color: red; }"
    lower = parse "Box:has(.error) { color: red; }"
    # `:has` is peeled off the structural selector either way (the engine can't
    # parse `:has`), leaving the same structural selector.
    upper.rules.first.selector.should eq lower.rules.first.selector
    upper.rules.first.selector.should_not contain ":has"
    upper.rules.first.selector.downcase.should_not contain ":has"
  end
end
