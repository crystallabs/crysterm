require "./spec_helper"

include Crysterm

# The `border-color` shorthand takes 1-4 colors in CSS TRBL order, with the
# standard fill-ins (1 -> all sides, 2 -> vertical/horizontal, 3 -> top/
# horizontal/bottom). The renderer paints each edge from its per-side color
# (`Border#top_fg`/`#right_fg`/…, falling back to whole-border `#fg`), so a
# multi-value `border-color` must populate those per-side slots — the analog
# of the multi-value `border-width` shorthand.
#
# The old form passed the whole multi-token value to `with_color`, which
# resolved e.g. `"red green blue yellow"` to the `-1` unknown sentinel and
# cleared every side. (`Crysterm::CSS::Properties.apply`.)
describe "CSS border-color shorthand (multi-value TRBL)" do
  it "applies four colors in top/right/bottom/left order" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-color", "red green blue yellow")
    b = s.border
    b.top_fg.should eq Colors.convert_cached("red")
    b.right_fg.should eq Colors.convert_cached("green")
    b.bottom_fg.should eq Colors.convert_cached("blue")
    b.left_fg.should eq Colors.convert_cached("yellow")
  end

  it "fills in two values as vertical/horizontal" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-color", "#ff0000 #0000ff")
    b = s.border
    b.top_fg.should eq 0xff0000    # vertical
    b.bottom_fg.should eq 0xff0000 # vertical
    b.left_fg.should eq 0x0000ff   # horizontal
    b.right_fg.should eq 0x0000ff  # horizontal
  end

  it "keeps a single color as a whole-border recolor (clearing per-side overrides)" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-top-color", "#ff0000")
    Crysterm::CSS::Properties.apply(s, "border-color", "#0000ff")
    b = s.border
    b.fg.should eq 0x0000ff
    b.@top_fg.should be_nil # per-side override cleared — getter falls back
    b.top_fg.should eq 0x0000ff
  end
end
