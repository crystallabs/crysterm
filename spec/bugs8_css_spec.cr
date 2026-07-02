require "./spec_helper"

include Crysterm

# Regression spec for the BUGS8 CSS fix: `apply_border_style` folded the *entire*
# `border-style` value as one keyword, so a valid multi-value TRBL form
# (`border-style: dashed dashed dashed dashed`) matched nothing and was silently
# dropped. `Border#type` is whole-border, so the fix honors the first token.

describe "BUGS8 multi-value border-style is honored (first token)" do
  it "applies a 4-value border-style instead of dropping it" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-style", "dashed dashed dashed dashed")
    s.border.type.should eq BorderType::Dashed
    s.border.left.should be > 0 # sides enabled, not dropped
  end

  it "applies a 2-value border-style using the first token" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-style", "dotted solid")
    s.border.type.should eq BorderType::Dotted
    s.border.top.should be > 0
  end

  it "still handles the single-value form (no regression)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-style", "double")
    s.border.type.should eq BorderType::Double
  end

  it "still hides the border on a multi-value none" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border", "solid") # enable first
    Crysterm::CSS::Properties.apply(s, "border-style", "none none")
    s.border.left.should eq 0
  end
end
