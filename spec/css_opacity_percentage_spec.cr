require "./spec_helper"

include Crysterm

# Focused specs for the CSS `opacity` property parser
# (`Crysterm::CSS::Properties.apply`). Per CSS Color 4 `opacity` accepts a
# `<number>` *or* a `<percentage>` (`opacity: 0.5` == `opacity: 50%`); both are
# clamped into `[0, 1]`. The percentage form is the interesting case — the old
# `value.to_f?` parse silently dropped it (`"50%".to_f?` → `nil`), leaving a
# theme's `opacity: 50%` fully opaque.
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
