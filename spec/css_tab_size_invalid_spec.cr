require "./spec_helper"

include Crysterm

# Specs for the CSS `tab-size` property parser (`Crysterm::CSS::Properties.apply`).
# Key case: an invalid value. CSS drops an unparseable declaration, leaving the
# cascaded (or default) tab width intact rather than collapsing to zero. The old
# `cells(value)` form mapped any non-length (blank `var()`, typo) to `0`,
# clobbering a previously-set tab-size.
describe "CSS tab-size" do
  it "parses an integer tab-size" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "tab-size", "8")
    s.tab_size.should eq 8
  end

  it "ignores an invalid value, keeping the previously-set tab-size" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "tab-size", "8")
    # An undefined `var()` collapses to ""; a typo is likewise not a cell count.
    # CSS drops such declarations.
    Crysterm::CSS::Properties.apply(s, "tab-size", "")
    s.tab_size.should eq 8
    Crysterm::CSS::Properties.apply(s, "tab-size", "garbage")
    s.tab_size.should eq 8
  end

  it "keeps the default tab-size when an invalid value is the only declaration" do
    s = Style.new
    default = s.tab_size
    Crysterm::CSS::Properties.apply(s, "tab-size", "")
    s.tab_size.should eq default
  end
end
