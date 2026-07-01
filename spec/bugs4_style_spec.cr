require "./spec_helper"

include Crysterm

# Regression specs for the BUGS4 style-engine fixes:
#
#  1. `@media` feature values carrying a unit (`40px`, `100%`, …) were dropped by
#     `FEATURE_RE` (which required a bare integer). A query whose only feature was
#     dropped produced an empty conjunction — and `[].all?` is `true` — so the
#     block matched *every* terminal instead of a narrow one. The unit is now
#     tolerated and ignored (crysterm features are in cell counts).
#  2. Functional pseudo-class specificity was matched case-sensitively, so
#     `:NOT(#id)`/`:WHERE(...)` were mis-scored as a plain class. Names are now
#     folded to lower case (they are case-insensitive per spec). A functional
#     pseudo-*element* argument (`::foo(bar)`) is also skipped rather than
#     re-scanned as further selector tokens.

describe "BUGS4 @media unit-tolerant feature values (fix #1)" do
  it "parses a unit'd value instead of dropping it" do
    q = Crysterm::CSS::MediaQuery.parse("(max-width: 40px)")
    q.conditions.should_not be_empty
    q.conditions.should eq [{"max-width", 40}]
  end

  it "matches only narrow terminals for (max-width: 40px), not all of them" do
    q = Crysterm::CSS::MediaQuery.parse("(max-width: 40px)")
    q.matches?(30, 24, 256).should be_true  # narrow: matches
    q.matches?(80, 24, 256).should be_false # wide: must NOT match (was the bug)
  end

  it "tolerates a percent unit and multiple conditions" do
    q = Crysterm::CSS::MediaQuery.parse("(min-width: 20) and (max-height: 10em)")
    q.conditions.should eq [{"min-width", 20}, {"max-height", 10}]
    q.matches?(30, 8, 256).should be_true
    q.matches?(30, 20, 256).should be_false # too tall
  end

  it "still parses a bare integer (no regression)" do
    q = Crysterm::CSS::MediaQuery.parse("(min-width: 80)")
    q.matches?(100, 24, 256).should be_true
    q.matches?(50, 24, 256).should be_false
  end
end

describe "BUGS4 CSS specificity case-insensitivity (fix #2)" do
  spec = ->(s : String) { Crysterm::CSS::Specificity.calculate(s) }

  it "scores an uppercase :NOT() like :not() (recurses into its argument)" do
    spec.call(":NOT(#id)").should eq({1, 0, 0})
    spec.call(":not(#id)").should eq({1, 0, 0})
  end

  it "treats :WHERE() as zero, like :where()" do
    spec.call(":WHERE(#a, .b)").should eq({0, 0, 0})
  end

  it "scores mixed-case :Is()/:Has() by their most specific argument" do
    spec.call(":Is(.a, #b)").should eq({1, 0, 0})
    spec.call(":Has(.a, Box Box)").should eq({0, 1, 0})
  end

  it "does not double-count a functional pseudo-element's argument" do
    spec.call("::highlight(x)").should eq({0, 0, 1})
  end
end
