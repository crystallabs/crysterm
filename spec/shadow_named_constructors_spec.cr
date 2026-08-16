require "./spec_helper"

include Crysterm

# `Shadow` carries the whole `SidedGeometry.named_constructors` set — the side
# orders, per-side forms and `.all` — at `Shadow`'s own resting extents (2-cell
# left/right bands, 1-cell top/bottom). Each bare form must agree with what
# `.from` gives for the same side, and naming any side must pin manual
# placement rather than leaving it to the scene light.

private def sides(sh : Crysterm::Shadow)
  {sh.left, sh.top, sh.right, sh.bottom}
end

describe "Shadow named constructors" do
  it "keeps the side orders" do
    sides(Shadow.ltrb(1, 2, 3, 4)).should eq({1, 2, 3, 4})
    sides(Shadow.trbl(1, 2, 3, 4)).should eq({4, 1, 2, 3})
    sides(Shadow.vh(1, 2)).should eq({2, 1, 2, 1})
  end

  it "places one side at that axis's resting extent" do
    sides(Shadow.left).should eq({2, 0, 0, 0})
    sides(Shadow.right).should eq({0, 0, 2, 0})
    sides(Shadow.top).should eq({0, 1, 0, 0})
    sides(Shadow.bottom).should eq({0, 0, 0, 1})
  end

  it "takes an explicit extent" do
    sides(Shadow.left(3)).should eq({3, 0, 0, 0})
    sides(Shadow.bottom(4)).should eq({0, 0, 0, 4})
  end

  it "places both sides of an axis" do
    sides(Shadow.horizontal).should eq({2, 0, 2, 0})
    sides(Shadow.horizontal(1)).should eq({1, 0, 1, 0})
    sides(Shadow.vertical).should eq({0, 1, 0, 1})
    sides(Shadow.vertical(2)).should eq({0, 2, 0, 2})
  end

  it "places all four, per-axis extents by default and uniform when given one" do
    sides(Shadow.all).should eq({2, 1, 2, 1})
    sides(Shadow.all(3)).should eq({3, 3, 3, 3})
  end

  it "agrees with `.from` on the same side" do
    {Crysterm::Side::Left, Crysterm::Side::Top, Crysterm::Side::Right,
     Crysterm::Side::Bottom, Crysterm::Side::Horizontal,
     Crysterm::Side::Vertical, Crysterm::Side::All}.each do |side|
      from = Shadow.from side
      named = case side
              in .left?       then Shadow.left
              in .top?        then Shadow.top
              in .right?      then Shadow.right
              in .bottom?     then Shadow.bottom
              in .horizontal? then Shadow.horizontal
              in .vertical?   then Shadow.vertical
              in .all?        then Shadow.all
              end
      sides(named).should eq sides(from)
    end
  end

  it "pins manual placement, so the scene light can't move the shadow" do
    Shadow.new.auto_sides?.should be_true # no side named: the light places it
    Shadow.left.auto_sides?.should be_false
    Shadow.bottom.auto_sides?.should be_false
    Shadow.horizontal.auto_sides?.should be_false
    Shadow.all.auto_sides?.should be_false
    Shadow.ltrb(1, 1, 1, 1).auto_sides?.should be_false
  end

  it "keeps the default opacity and no glyph ramp" do
    sh = Shadow.right 3
    sh.opacity.should eq 0.5
    sh.ratio.should be_nil
    sh.glyphs?.should be_false
  end
end

describe "Padding/Margin named constructors" do
  it "stays at one cell per side" do
    p = Padding.left
    {p.left, p.top, p.right, p.bottom}.should eq({1, 0, 0, 0})
    m = Margin.vertical
    {m.left, m.top, m.right, m.bottom}.should eq({0, 1, 0, 1})
    a = Padding.all
    {a.left, a.top, a.right, a.bottom}.should eq({1, 1, 1, 1})
    a3 = Padding.all(3)
    {a3.left, a3.top, a3.right, a3.bottom}.should eq({3, 3, 3, 3})
  end
end
