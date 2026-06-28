require "./spec_helper"

include Crysterm

# Focused specs for the CSS `box-shadow` property parser
# (`Crysterm::CSS::Properties.apply`). The interesting case is a *blank* value:
# an undefined `var(--x)` collapses to "" before reaching the property, and per
# CSS's "drop the invalid declaration" rule it must be ignored — leaving any
# previously-cascaded shadow intact. The old unguarded form treated an empty
# value as "enable the default drop shadow", silently switching a shadow *on*
# from nothing (the mirror of the `font`/`text-decoration`/`padding`/`margin`
# blank-clobber guards).
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
    # An undefined `var()` collapses to "" before reaching the property. CSS
    # drops such a declaration; it must NOT switch a shadow on from nothing.
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
