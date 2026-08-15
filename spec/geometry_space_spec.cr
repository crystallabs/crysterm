require "./spec_helper"

include Crysterm

# #10 / API.md §4.3 — one parent-relative coordinate space. The r* family,
# x/y/pos and #geometry all read the *spec space*: the value the bare setter
# would need to reproduce the current placement, so read-modify-write
# round-trips are no-ops. The absolute last-rendered box moved to
# #absolute_geometry.

# An inset parent (border + 1-cell padding => ileft/itop == 2) for the
# round-trip specs: any drift between spec space and the readers shows up
# doubled through it.
private def inset_parent(s)
  Widget::Box.new parent: s, left: 3, top: 2, width: 30, height: 15,
    style: Style.new(border: true, padding: Padding.new(1))
end

describe "geometry/pos coordinate space (#10)" do
  describe "the r* family (spec space)" do
    it "rleft/rtop equal the set specs inside an inset parent" do
      s = headless_screen(40, 20)
      parent = inset_parent(s)
      w = Widget::Box.new parent: parent, left: 4, top: 3, width: 5, height: 2
      w.rleft.should eq 4
      w.rtop.should eq 3
    end

    it "rright/rbottom equal the set far-edge specs" do
      s = headless_screen(40, 20)
      parent = inset_parent(s)
      w = Widget::Box.new parent: parent, right: 5, bottom: 4, width: 5, height: 2
      w.rright.should eq 5
      w.rbottom.should eq 4
    end

    it "left = rleft / top = rtop are no-ops, margins included" do
      s = headless_screen(40, 20)
      parent = inset_parent(s)
      w = Widget::Box.new parent: parent, left: 4, top: 3, width: 5, height: 2,
        style: Style.new(margin: Margin.new(left: 2, top: 1, right: 1, bottom: 1))
      ax = w.aleft
      ay = w.atop
      w.left = w.rleft
      w.top = w.rtop
      w.left.should eq 4
      w.top.should eq 3
      w.aleft.should eq ax
      w.atop.should eq ay
    end

    it "round-trips percent and center specs to the same resolved position" do
      s = headless_screen(40, 20)
      parent = inset_parent(s)
      w = Widget::Box.new parent: parent, left: "25%", top: "center", width: 5, height: 2
      ax = w.aleft
      ay = w.atop
      w.left = w.rleft
      w.top = w.rtop
      w.aleft.should eq ax
      w.atop.should eq ay
    end

    it "round-trips a far-anchored widget position-preserving (pins the near edge)" do
      s = headless_screen(40, 20)
      parent = inset_parent(s)
      w = Widget::Box.new parent: parent, right: 5, bottom: 4, width: 6, height: 2,
        style: Style.new(margin: Margin.new(left: 1, top: 1, right: 2, bottom: 1))
      ax = w.aleft
      ay = w.atop
      w.left = w.rleft
      w.top = w.rtop
      w.aleft.should eq ax
      w.atop.should eq ay
    end
  end

  describe "Widget#geometry" do
    it "is live and parent-relative — no render needed" do
      s = headless_screen(40, 20)
      parent = inset_parent(s)
      w = Widget::Box.new parent: parent, left: 4, top: 3, width: 5, height: 2
      w.geometry.should eq Rectangle.new(4, 3, 5, 2)
    end

    it "geometry = geometry is a no-op through nesting, insets and margins" do
      s = headless_screen(40, 20)
      outer = inset_parent(s)
      inner = Widget::Box.new parent: outer, left: 1, top: 1, width: 20, height: 10,
        style: Style.new(border: true)
      w = Widget::Box.new parent: inner, left: 2, top: 1, width: 5, height: 2,
        style: Style.new(margin: Margin.new(left: 1, top: 1, right: 0, bottom: 0))
      ax = w.aleft
      ay = w.atop
      aw = w.awidth
      ah = w.aheight
      w.geometry = w.geometry
      w.aleft.should eq ax
      w.atop.should eq ay
      w.awidth.should eq aw
      w.aheight.should eq ah
    end

    it "top_left == pos and size == (awidth, aheight) under BorderBox" do
      s = headless_screen(40, 20)
      parent = inset_parent(s)
      w = Widget::Box.new parent: parent, left: 4, top: 3, width: 5, height: 2
      g = w.geometry
      g.top_left.should eq w.pos
      g.width.should eq w.awidth
      g.height.should eq w.aheight
    end

    it "reports and round-trips the content-box size under ContentBox" do
      s = headless_screen(40, 20)
      w = Widget::Box.new parent: s, left: 4, top: 3, width: 5, height: 2,
        style: Style.new(border: true)
      w.box_sizing = Widget::BoxSizing::ContentBox
      aw = w.awidth # content 5 + border 2
      w.geometry.width.should eq 5
      w.geometry = w.geometry
      w.width_spec.should eq 5
      w.awidth.should eq aw
    end
  end

  describe "Widget#absolute_geometry" do
    it "is nil before render and the last-rendered absolute box after" do
      s = headless_screen(40, 20)
      parent = inset_parent(s)
      w = Widget::Box.new parent: parent, left: 4, top: 3, width: 5, height: 2
      w.absolute_geometry.nil?.should be_true
      s.repaint
      abs = w.absolute_geometry
      abs.nil?.should be_false
      abs = abs.not_nil!
      # Shifted from the parent-relative reader by the parent's absolute
      # content origin (unclipped, margin-free case).
      abs.x.should eq parent.aleft + parent.ileft + w.x
      abs.y.should eq parent.atop + parent.itop + w.y
      abs.width.should eq w.awidth
      abs.height.should eq w.aheight
    end
  end
end
