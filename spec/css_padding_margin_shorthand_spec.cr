require "./spec_helper"

include Crysterm

# Specs for the CSS `padding`/`margin` shorthand parsers
# (`Crysterm::CSS::Properties.apply`). As with `font`/`text-decoration`, a
# blank value (undefined `var(--x)` collapsed to "") must be dropped (CSS's
# "drop the invalid declaration" rule), not reset the box to default (which
# `parse_sides("") -> nil -> Padding.default`/`Margin.default` would do),
# clobbering a value a lower-priority cascade rule had set.
describe "CSS padding/margin shorthand" do
  it "applies a 1-4 value padding shorthand" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "padding", "2")
    s.padding.left.should eq 2
    s.padding.top.should eq 2
    s.padding.right.should eq 2
    s.padding.bottom.should eq 2
  end

  it "drops a blank padding value, keeping a previously-set padding" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "padding", "3")
    # Undefined var() collapses to "" (or whitespace-only) before reaching here.
    Crysterm::CSS::Properties.apply(s, "padding", "")
    s.padding.left.should eq 3
    s.padding.top.should eq 3
    Crysterm::CSS::Properties.apply(s, "padding", "   ")
    s.padding.right.should eq 3
    s.padding.bottom.should eq 3
  end

  it "drops a blank margin value, keeping a previously-set margin" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "margin", "4")
    Crysterm::CSS::Properties.apply(s, "margin", "")
    s.margin.left.should eq 4
    s.margin.top.should eq 4
    s.margin.right.should eq 4
    s.margin.bottom.should eq 4
  end
end
