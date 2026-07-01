require "./spec_helper"

include Crysterm

# CSS `opacity` (`Crysterm::CSS::Properties.apply`) accepts a `<number>` or a
# `<percentage>` per CSS Color 4 (`opacity: 0.5` == `opacity: 50%`), clamped to
# `[0, 1]`. Regression: the old `value.to_f?` parse silently dropped the
# percentage form (`"50%".to_f?` -> `nil`), leaving `opacity: 50%` fully opaque.
describe "CSS opacity" do
  it "parses a numeric opacity" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "opacity", "0.5")
    s.alpha.should eq 0.5
  end

  it "parses a percentage opacity (CSS Color 4)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "opacity", "50%")
    s.alpha.should eq 0.5
  end

  it "clamps an out-of-range percentage into [0, 1]" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "opacity", "150%")
    s.alpha.should eq 1.0
  end

  it "ignores a blank/non-numeric value, leaving the alpha unset" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "opacity", "")
    s.alpha.should be_nil
  end
end
