require "./spec_helper"

include Crysterm

# Focused spec for the per-side `border-<side>` *shorthand* with a color
# *function* value (`Crysterm::CSS::Properties.apply`).
#
# A color function carries internal spaces/commas (`rgb(30, 30, 46)`), so the
# shorthand must tokenize on top-level whitespace only — keeping the function
# whole — exactly like the `border` shorthand and the `border-color` shorthand
# already do. The old plain `value.split` shredded the function into junk
# fragments (`rgb(30,`, `30,`, `46)`), each resolving to the `-1` "unknown"
# sentinel, so the per-side color came out wrong instead of the real color.
describe "CSS border-<side> shorthand with a color function" do
  it "keeps an rgb(...) value whole and routes it to the per-side color slot" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-left", "solid rgb(0, 128, 255)")
    b = s.border
    # The function resolves to its true color on the left edge only.
    b.fg_left.should eq 0x0080ff
    b.left_fg.should eq 0x0080ff
    # Width/type from the same shorthand are still honored.
    b.type.should eq BorderType::Line
    b.left.should eq 1
    # Other sides untouched.
    b.fg_top.should be_nil
    b.fg_right.should be_nil
    b.fg_bottom.should be_nil
  end
end
