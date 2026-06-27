require "./spec_helper"

include Crysterm

# Focused specs for the CSS `z-index` property parser
# (`Crysterm::CSS::Properties.apply`). The interesting case is the *invalid*
# value: per CSS an unparseable declaration is dropped, leaving any
# previously-cascaded value intact — it must NOT silently clear a z-index a
# lower-priority rule had set (e.g. the theme's `Menu { z-index: 10 }` overlay
# promotion, which an author rule with an unresolved `var()` would otherwise
# un-composite).
describe "CSS z-index" do
  it "parses an integer z-index" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "z-index", "10")
    s.z_index.should eq 10
  end

  it "parses a negative z-index" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "z-index", "-3")
    s.z_index.should eq -3
  end

  it "clears the z-index on `auto` (case-insensitively)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "z-index", "10")
    Crysterm::CSS::Properties.apply(s, "z-index", "Auto")
    s.z_index.should be_nil
  end

  it "ignores an unparseable value, keeping the previously-set z-index" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "z-index", "10")
    # An undefined `var()` collapses to "" before reaching the property; a typo
    # or any non-integer is likewise invalid. CSS drops such a declaration.
    Crysterm::CSS::Properties.apply(s, "z-index", "")
    s.z_index.should eq 10
    Crysterm::CSS::Properties.apply(s, "z-index", "garbage")
    s.z_index.should eq 10
  end

  it "leaves z-index unset for an invalid value when none was set" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "z-index", "")
    s.z_index.should be_nil
  end
end
