require "./spec_helper"

include Crysterm

# Focused spec for `border-<side>` shorthand with a color function value
# (`Crysterm::CSS::Properties.apply`).
#
# A color function carries internal spaces/commas (`rgb(30, 30, 46)`), so the
# shorthand must tokenize on top-level whitespace only, keeping the function
# whole, like `border` and `border-color` already do. Plain `value.split` used
# to shred it into junk fragments (`rgb(30,`, `30,`, `46)`) that each resolved
# to the `-1` "unknown" sentinel.
describe "CSS border-<side> shorthand with a color function" do
  it "keeps an rgb(...) value whole and routes it to the per-side color slot" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-left", "solid rgb(0, 128, 255)")
    b = s.border
    # Resolves to the true color on the left edge only.
    b.left_fg.should eq 0x0080ff
    b.left_fg.should eq 0x0080ff
    # Width/type from the same shorthand still honored.
    b.type.should eq BorderType::Solid
    b.left.should eq 1
    # Other sides untouched.
    b.top_fg.should be_nil
    b.right_fg.should be_nil
    b.bottom_fg.should be_nil
  end
end
