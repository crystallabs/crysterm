require "./spec_helper"

include Crysterm

# Specs for the CSS `box-shadow` property parser (`Crysterm::CSS::Properties.apply`).
# Key case: a blank value (an undefined `var(--x)` collapses to ""). CSS drops
# such an invalid declaration, leaving a cascaded shadow intact. The old
# unguarded form treated blank as "enable the default drop shadow", switching a
# shadow on from nothing.
describe "CSS box-shadow" do
  it "enables a drop shadow for a real value" do
    s = Style.new
    s.shadow.any?.should be_false
    Crysterm::CSS::Properties.apply(s, "box-shadow", "0 4px 8px black")
    s.shadow.any?.should be_true
  end

  it "disables the shadow on `none`" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "box-shadow", "0 4px 8px black")
    Crysterm::CSS::Properties.apply(s, "box-shadow", "none")
    s.shadow.any?.should be_false
  end

  it "drops a blank value instead of enabling a default shadow" do
    s = Style.new
    # An undefined `var()` collapses to ""; CSS drops the declaration rather
    # than switching a shadow on.
    Crysterm::CSS::Properties.apply(s, "box-shadow", "")
    s.shadow.any?.should be_false
  end

  it "drops a blank value, keeping a previously-set shadow" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "box-shadow", "0 4px 8px black")
    Crysterm::CSS::Properties.apply(s, "box-shadow", "")
    s.shadow.any?.should be_true
  end
end
