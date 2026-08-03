require "./spec_helper"

include Crysterm

# `border-width` takes 1-4 cell widths in CSS TRBL order, with the standard
# 1/2/3-value fill-ins, like `padding`/`margin`. Regression: only a single value
# was honored; a multi-value form (e.g. `0 0 1px 0`, the Qt tab/header underline)
# was fed whole to the single-token length parser, failed, and collapsed every
# side to 0. (`Crysterm::CSS::Properties.apply`.)
describe "CSS border-width shorthand" do
  it "applies four TRBL widths to the matching sides" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-width", "1 2 3 4")
    s.border.top.should eq 1
    s.border.right.should eq 2
    s.border.bottom.should eq 3
    s.border.left.should eq 4
  end

  it "fills in two values as vertical/horizontal" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-width", "1 2")
    s.border.top.should eq 1
    s.border.bottom.should eq 1
    s.border.left.should eq 2
    s.border.right.should eq 2
  end

  it "fills in three values as top/horizontal/bottom" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-width", "1 2 3")
    s.border.top.should eq 1
    s.border.left.should eq 2
    s.border.right.should eq 2
    s.border.bottom.should eq 3
  end

  it "applies a single-edge underline to the bottom only (Qt tab/header pattern)" do
    # `0 0 1 0`: only the bottom edge is drawn — the fill-in must not smear the
    # width across the other three sides.
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-width", "0 0 1 0")
    s.border.top.should eq 0
    s.border.right.should eq 0
    s.border.bottom.should eq 1
    s.border.left.should eq 0
  end

  it "resolves a sub-cell edge of the shorthand to no border, as the longhands do" do
    # A cell grid can't draw thinner than a cell, so a hairline resolves to
    # nothing — identically in every border-width spelling (see
    # `Properties.border_cells?`). The Qt `0 0 1px 0` tab underline therefore
    # renders as no underline rather than a full-cell rule.
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-width", "0 0 1px 0")
    {s.border.top, s.border.right, s.border.bottom, s.border.left}.should eq({0, 0, 0, 0})
  end

  it "still honors a single value on all sides" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "border-width", "2")
    s.border.top.should eq 2
    s.border.right.should eq 2
    s.border.bottom.should eq 2
    s.border.left.should eq 2
  end

  it "drops a blank value rather than clobbering the border to 0" do
    # An undefined `var()` collapses to blank; CSS drops the invalid declaration,
    # leaving an already-set border intact.
    s = Style.new
    s.border = Crysterm::Border.new(left: 4, top: 4, right: 4, bottom: 4)
    Crysterm::CSS::Properties.apply(s, "border-width", "")
    s.border.top.should eq 4
    s.border.left.should eq 4
  end
end
