require "./spec_helper"

include Crysterm

# `Crysterm::CSS::MediaQuery` with a bare (featureless) media *type*.
#
# A featureless query with a supported media type (`@media screen` / `@media
# all`) must match a terminal — a terminal is a screen device. The parser used
# to reject *every* featureless non-empty query as unmatchable, which also
# killed `screen`/`all`, contradicting the media-type scan that classifies them
# as satisfiable. Only unsupported types (`print`/`speech`/…) and negation
# (`not …`) stay unmatchable.
describe "Crysterm::CSS::MediaQuery bare media type" do
  it "matches a bare `screen` (a terminal is a screen device)" do
    q = Crysterm::CSS::MediaQuery.parse("screen")
    q.matchable?.should be_true
    q.matches?(100, 24, 256).should be_true
  end

  it "matches a bare `all`" do
    q = Crysterm::CSS::MediaQuery.parse("all")
    q.matchable?.should be_true
    q.matches?(1, 1, 2).should be_true
  end

  it "matches `only screen` (the `only` connector is inert)" do
    q = Crysterm::CSS::MediaQuery.parse("only screen")
    q.matchable?.should be_true
    q.matches?(100, 24, 256).should be_true
  end

  it "still rejects a bare unsupported type (`print`)" do
    q = Crysterm::CSS::MediaQuery.parse("print")
    q.matchable?.should be_false
    q.matches?(100, 24, 256).should be_false
  end

  it "still rejects a negated query (`not screen`)" do
    q = Crysterm::CSS::MediaQuery.parse("not screen")
    q.matchable?.should be_false
    q.matches?(100, 24, 256).should be_false
  end

  it "still honors a feature query combined with `screen`" do
    q = Crysterm::CSS::MediaQuery.parse("screen and (min-width: 80)")
    q.matches?(100, 24, 256).should be_true
    q.matches?(50, 24, 256).should be_false
  end

  it "still rejects an unparsable feature even on a `screen` query" do
    q = Crysterm::CSS::MediaQuery.parse("screen and (orientation: portrait)")
    q.matchable?.should be_false
    q.matches?(100, 24, 256).should be_false
  end

  it "matches a bare `screen` OR-ed with a feature query when either side holds" do
    q = Crysterm::CSS::MediaQuery.parse("screen, (min-width: 500)")
    # `screen` alone always matches, so the whole OR matches regardless of width.
    q.matches?(100, 24, 256).should be_true
  end

  it "does not raise on a feature value beyond Int32 range (treats it unmatchable)" do
    # `(max-width: 3000000000)` exceeds Int32::MAX; the parser must not raise
    # (its contract) — the out-of-range value makes the query unmatchable.
    q = Crysterm::CSS::MediaQuery.parse("(max-width: 3000000000)")
    q.matchable?.should be_false
    q.matches?(100, 24, 256).should be_false
  end

  it "parses a whole stylesheet with an overflowing @media value without raising" do
    sheet = Crysterm::CSS::Stylesheet.parse("@media (min-width: 9999999999) { Box { color: red; } }")
    sheet.rules.each(&.media.try(&.matches?(100, 24, 256))) # exercises evaluation
  end
end
