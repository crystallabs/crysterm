require "./spec_helper"

include Crysterm

# Specs for the CSS `visibility`/`display` property parsers
# (`Crysterm::CSS::Properties.apply`). Key case, as with `z-index` (see
# `css_z_index_spec.cr`): an invalid value must be dropped rather than forcing
# the widget visible, which would un-hide a widget a lower-priority rule hid.
describe "CSS visibility" do
  it "shows on `visible` and hides on `hidden` (case-insensitively)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "visibility", "hidden")
    s.visible?.should be_false
    Crysterm::CSS::Properties.apply(s, "visibility", "Visible")
    s.visible?.should be_true
  end

  it "hides on `collapse` (treated as hidden)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "visibility", "collapse")
    s.visible?.should be_false
  end

  it "ignores an unparseable value, keeping a previously-set hidden state" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "visibility", "hidden")
    # An undefined `var()` collapses to ""; a typo is likewise unrecognized. CSS
    # drops such a declaration rather than un-hiding the widget.
    Crysterm::CSS::Properties.apply(s, "visibility", "")
    s.visible?.should be_false
    Crysterm::CSS::Properties.apply(s, "visibility", "garbage")
    s.visible?.should be_false
  end
end

describe "CSS display" do
  it "hides on `none` and shows on any other recognized value" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "display", "none")
    s.visible?.should be_false
    Crysterm::CSS::Properties.apply(s, "display", "block")
    s.visible?.should be_true
  end

  it "ignores an empty value, keeping a previously-set `display: none`" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "display", "none")
    # An undefined `var()` collapses to "" — must not un-hide the widget.
    Crysterm::CSS::Properties.apply(s, "display", "")
    s.visible?.should be_false
  end
end
