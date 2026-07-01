require "./spec_helper"

include Crysterm

# Focused specs for the CSS `text-decoration` shorthand parser
# (`Crysterm::CSS::Properties.apply`). Key case: a blank value (an undefined
# `var(--x)` collapsed to "") must be dropped per CSS's "invalid declaration"
# rule, not treated as a shorthand reset that clobbers
# underline/blink/strike/reverse. A genuine value with no decoration word still
# resets, like the `font` shorthand.
describe "CSS text-decoration shorthand" do
  it "sets underline / blink / line-through / reverse" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "text-decoration", "underline blink line-through reverse")
    s.underline?.should be_true
    s.blink?.should be_true
    s.strike?.should be_true
    s.reverse?.should be_true
  end

  it "treats `inverse` as the reverse alias" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "text-decoration", "inverse")
    s.reverse?.should be_true
  end

  # Regression: a blank value must not switch off a decoration a
  # lower-priority rule had set.
  it "drops a blank value, keeping previously-set decorations" do
    s = Style.new
    s.underline = true
    s.blink = true
    s.strike = true
    s.reverse = true
    # Undefined var() collapses to "" before reaching the property.
    Crysterm::CSS::Properties.apply(s, "text-decoration", "")
    s.underline?.should be_true
    s.blink?.should be_true
    s.strike?.should be_true
    s.reverse?.should be_true
    # Whitespace-only value is dropped too.
    Crysterm::CSS::Properties.apply(s, "text-decoration", "   ")
    s.underline?.should be_true
    s.blink?.should be_true
    s.strike?.should be_true
    s.reverse?.should be_true
  end

  # A genuine value with no matching decoration word still resets (shorthand
  # absent -> off); the guard only drops the blank case.
  it "still resets decorations for a real value with no matching word" do
    s = Style.new
    s.underline = true
    s.reverse = true
    Crysterm::CSS::Properties.apply(s, "text-decoration", "none")
    s.underline?.should be_false
    s.reverse?.should be_false
  end
end
