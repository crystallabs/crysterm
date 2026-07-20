require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 B16-26 — the `border-color` shorthand's 2-4
# token path used to resolve each token through `coerce_color_int` and assign
# the result unconditionally: a malformed color function (`nil`) clobbered a
# per-side color a lower-priority rule had set, and an unknown color name (the
# `-1` sentinel) got stored, painting that side in the terminal-default color.
# Both violate CSS's drop-the-invalid-declaration rule that the same file
# already implements for the 1-token path (`with_color`) and the `border`
# shorthand (`parse_border`). (`Crysterm::CSS::Properties.apply`.)
describe "CSS border-color shorthand (multi-value) invalid-declaration handling" do
  it "drops the whole declaration on a malformed color function, keeping the prior color" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-top-color", "red")
    Crysterm::CSS::Properties.apply(s, "border-color", "rgb(, 0, 0) blue")
    s.border.@top_fg.should eq Colors.convert_cached("red")
    s.border.top_fg.should eq Colors.convert_cached("red")
  end

  it "drops the whole declaration on an unknown color name, not storing the -1 sentinel" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-color", "bleu blue")
    s.border.@top_fg.should be_nil
    s.border.top_fg.should be_nil
  end

  it "still applies a fully valid multi-value declaration" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-color", "red green blue yellow")
    b = s.border
    b.top_fg.should eq Colors.convert_cached("red")
    b.right_fg.should eq Colors.convert_cached("green")
    b.bottom_fg.should eq Colors.convert_cached("blue")
    b.left_fg.should eq Colors.convert_cached("yellow")
  end

  it "keeps a genuine transparent (a valid Int32 -1) distinct from the unknown-name drop case" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-color", "transparent blue")
    s.border.top_fg.should eq(-1)
    s.border.bottom_fg.should eq(-1)
    s.border.left_fg.should eq Colors.convert_cached("blue")
    s.border.right_fg.should eq Colors.convert_cached("blue")
  end
end
