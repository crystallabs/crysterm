require "./spec_helper"

include Crysterm

# Focused spec for the CSS `background-size` longhand parser
# (`Crysterm::CSS::Properties.apply`). An undefined `var(--x)` collapses to ""
# before reaching the property, and per CSS's "drop the invalid declaration"
# rule it must be ignored — leaving any previously-cascaded size intact. The old
# unguarded form ran `parse_background_size("")`, which matches no keyword and
# falls through to its `Cover` default, silently *resetting* a `background-size`
# a lower-priority rule had set (and marking it `specified?`). The sibling
# `background-image` longhand already guards this exact case; the size longhand
# must too.
describe "CSS background-size blank longhand" do
  it "drops a blank value, keeping a previously-set size" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-size", "contain")
    s.background_size.should eq Style::BackgroundSize::Contain
    s.specified?(:background_size).should be_true
    # A collapsed undefined `var()` reaches here as "". It must NOT reset the
    # size to the `Cover` fallback — that would drop a lower-priority rule.
    Crysterm::CSS::Properties.apply(s, "background-size", "")
    s.background_size.should eq Style::BackgroundSize::Contain
  end

  it "leaves an unset size untouched (never marks it specified) on a blank value" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-size", "")
    s.specified?(:background_size).should be_false
  end

  it "still applies an explicit value" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "background-size", "100% 100%")
    s.background_size.should eq Style::BackgroundSize::Stretch
  end
end
