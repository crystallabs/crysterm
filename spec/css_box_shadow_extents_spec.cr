require "./spec_helper"

include Crysterm

# `box-shadow`'s offset-x/offset-y pair maps onto real `Shadow` extents in the
# value's own CSS units (`ch`/`em` ≈ a cell, `px` through the configured
# px-per-cell, unitless read as `px` per QSS): sign picks the side, magnitude
# the band extent, and a sub-cell magnitude selects the thin eighth-block
# shadow (`Shadow#ratio`) at a 1-cell band.

describe "CSS box-shadow extents" do
  it "maps cell-denominated (ch) offsets to right/bottom band extents" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "box-shadow", "2ch 1ch")
    sh = s.shadow
    sh.right.should eq 2
    sh.bottom.should eq 1
    sh.left.should eq 0
    sh.top.should eq 0
    sh.ratio.should be_nil
    sh.auto_sides?.should be_false # explicit offsets pin the sides
    sh.opacity.should eq 0.5
  end

  it "maps px offsets through the configured cell metrics" do
    s = Style.new
    # 10px/cell horizontally, aspect 2.0 vertically: 20px → 2 cells / 1 row.
    Crysterm::CSS::Properties.apply(s, "box-shadow", "20px 20px")
    sh = s.shadow
    sh.right.should eq 2
    sh.bottom.should eq 1
    sh.ratio.should be_nil
  end

  it "reads a unitless offset as px, per QSS" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "box-shadow", "20 20")
    sh = s.shadow
    sh.right.should eq 2 # 20 ≡ 20px, never 20 cells
    sh.bottom.should eq 1
  end

  it "maps negative offsets to the left/top sides" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "box-shadow", "-2ch -1ch")
    sh = s.shadow
    sh.left.should eq 2
    sh.top.should eq 1
    sh.right.should eq 0
    sh.bottom.should eq 0
  end

  it "maps a sub-cell offset to a thin eighth-block shadow" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "box-shadow", "0.125ch 0.125ch")
    sh = s.shadow
    sh.right.should eq 1
    sh.bottom.should eq 1
    sh.ratio.should eq 0.125
    sh.glyphs?.should be_true # renders on the glyph (thin) path
  end

  it "gives the classic 1px QSS nudge shadow a thin band" do
    s = Style.new
    # 1px → 0.1 cells horizontally, 0.05 vertically: 1-cell thin bands.
    Crysterm::CSS::Properties.apply(s, "box-shadow", "1px 1px")
    sh = s.shadow
    sh.right.should eq 1
    sh.bottom.should eq 1
    sh.ratio.should eq 0.1
  end

  it "combines extents with a trailing opacity" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "box-shadow", "2ch 1ch black 0.3")
    sh = s.shadow
    sh.right.should eq 2
    sh.bottom.should eq 1
    sh.opacity.should eq 0.3
  end

  it "falls back to the default drop shadow for a both-zero glow" do
    s = Style.new
    Crysterm::CSS::Properties.apply(s, "box-shadow", "0 0 10px red")
    sh = s.shadow
    sh.right.should eq 2 # default extents, light-placed
    sh.bottom.should eq 1
    sh.auto_sides?.should be_true
  end

  it "gives the pressed-into-a-thin-shadow effect a pure-CSS spelling" do
    s = headless_screen(20, 6)
    b = Widget::Button.new parent: s, top: 1, left: 2, width: 6, height: 1, text: "OK"
    s.stylesheet = "Button { box-shadow: 0.25ch 0.25ch; } Button:pressed { box-shadow: 0.125ch 0.125ch; }"
    s.repaint
    b.styles.normal.shadow.ratio.should eq 0.25
    b.styles.selected.shadow.ratio.should eq 0.125
  end
end
