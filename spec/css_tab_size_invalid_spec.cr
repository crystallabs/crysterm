require "./spec_helper"

include Crysterm

# Focused specs for the CSS `tab-size` property parser
# (`Crysterm::CSS::Properties.apply`). The interesting case is the *invalid*
# value: per CSS an unparseable declaration is dropped, leaving any
# previously-cascaded (or the default) tab width intact — it must NOT silently
# collapse the tab stops to zero width. The old `cells(value)` form mapped any
# non-length (an undefined `var()` collapsed to "", or a typo) to `0`,
# clobbering a previously-set tab-size — the mirror of the `z-index`/`opacity`
# invalid-value bugs.
describe "CSS tab-size" do
  it "parses an integer tab-size" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "tab-size", "8")
    s.tab_size.should eq 8
  end

  it "ignores an invalid value, keeping the previously-set tab-size" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "tab-size", "8")
    # An undefined `var()` collapses to "" before reaching the property; a typo
    # is likewise not a cell count. CSS drops such a declaration.
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
