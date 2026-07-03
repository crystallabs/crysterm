require "./spec_helper"

# Behavior lock for `Crysterm::CSS::Case` — crysterm's single CSS case-folding
# policy. Pure string logic; the load-bearing edges are which tokens fold and
# which must NOT (custom properties), plus the no-alloc already-lowercase path.
describe Crysterm::CSS::Case do
  describe ".fold_keyword" do
    it "folds keywords to lowercase" do
      Crysterm::CSS::Case.fold_keyword("NONE").should eq "none"
      Crysterm::CSS::Case.fold_keyword("Ease-In-Out").should eq "ease-in-out"
    end

    it "returns the same object (no allocation) when already folded" do
      s = "none"
      Crysterm::CSS::Case.fold_keyword(s).should be s
    end
  end

  describe ".fold_property" do
    it "folds ordinary property names" do
      Crysterm::CSS::Case.fold_property("COLOR").should eq "color"
      Crysterm::CSS::Case.fold_property("Border-Width").should eq "border-width"
    end

    it "leaves custom properties (--Foo) case-sensitive" do
      Crysterm::CSS::Case.fold_property("--Foo").should eq "--Foo"
      Crysterm::CSS::Case.fold_property("--Foo").should_not eq Crysterm::CSS::Case.fold_property("--foo")
    end
  end

  describe ".fold_unit" do
    it "folds unit tokens" do
      Crysterm::CSS::Case.fold_unit("PX").should eq "px"
      Crysterm::CSS::Case.fold_unit("VW").should eq "vw"
      Crysterm::CSS::Case.fold_unit("MS").should eq "ms"
    end
  end

  describe ".at_rule?" do
    it "matches an @<name> prelude case-insensitively" do
      Crysterm::CSS::Case.at_rule?("@MEDIA (min-width: 10)", "media").should be_true
      Crysterm::CSS::Case.at_rule?("@Layer base", "layer").should be_true
    end

    it "rejects a different at-rule name" do
      Crysterm::CSS::Case.at_rule?("@media screen", "layer").should be_false
      Crysterm::CSS::Case.at_rule?("color: red", "media").should be_false
    end

    it "matches an exact @<name> prelude with no trailing text" do
      Crysterm::CSS::Case.at_rule?("@media", "media").should be_true
    end

    it "rejects a prelude too short to hold the name" do
      Crysterm::CSS::Case.at_rule?("@me", "media").should be_false
      Crysterm::CSS::Case.at_rule?("@", "media").should be_false
    end
  end

  describe "VAR_CALL" do
    it "matches a var( opener case-insensitively" do
      "VAR(--x)".should match Crysterm::CSS::Case::VAR_CALL
      "var(--x)".should match Crysterm::CSS::Case::VAR_CALL
      "color: red".should_not match Crysterm::CSS::Case::VAR_CALL
    end
  end
end
