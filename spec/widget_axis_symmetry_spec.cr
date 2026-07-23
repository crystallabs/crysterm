require "./spec_helper"

include Crysterm

# Axis-symmetry lock for the horizontal/vertical geometry mirrors
# `aleft`/`atop`, `aright`/`abottom` (widget_position.cr) and `awidth`/`aheight`
# (widget_size.cr). These four+two methods are hand-written near-duplicates that
# differ only by their per-axis tokens (left↔top, awidth↔aheight, ileft↔itop,
# iright↔ibottom, aright↔abottom, …). O3-08 macro-generates each mirror pair
# from one body; a single mistyped token there would silently skew ONE axis, so
# this spec pins the exact per-axis output and the cross-axis mirror relation.
#
# The fixture is deliberately NOT square: width 10 ≠ height 6, and the container
# insets are all-distinct (1/2/4/3, left/top/right/bottom). A square box or
# uniform insets would let an accidentally-unswapped `awidth`/`aheight` or a
# near/far inset swap (`ileft`↔`iright`) produce identical numbers on both axes,
# hiding the very bug this spec exists to catch.
private def make_fixture
  s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 80, height: 24)
  # Container at the window origin with asymmetric padding so every inset
  # (ileft=1, itop=2, iright=4, ibottom=3) is distinct.
  cont = Widget::Box.new parent: s, left: 0, top: 0, width: 40, height: 20,
    style: Crysterm::Style.new(padding: Crysterm::Padding.new(1, 2, 4, 3))
  {s, cont}
end

describe "widget axis-mirror geometry (O3-08 macro guard)" do
  it "resolves a near-anchored (left+top) widget to the expected coords" do
    _s, cont = make_fixture
    # left:3/top:1 offsets, inside the container's content box (after the
    # asymmetric insets); a fixed 10×6 size.
    lt = Widget::Box.new parent: cont, left: 3, top: 1, width: 10, height: 6

    # aleft = cont.aleft(0) + left(3) + ileft(1); atop = 0 + top(1) + itop(2).
    lt.aleft.should eq 4
    lt.atop.should eq 3
    # Far edges measure the gap from the WINDOW far edge plus the container's
    # far inset: aright = window.awidth(80) - (aleft+awidth) + iright(4);
    # abottom = window.aheight(24) - (atop+aheight) + ibottom(3).
    lt.aright.should eq 70
    lt.abottom.should eq 18
    lt.awidth.should eq 10
    lt.aheight.should eq 6
  end

  it "resolves a far-anchored (right+bottom) widget to the expected coords" do
    _s, cont = make_fixture
    rb = Widget::Box.new parent: cont, right: 3, bottom: 1, width: 10, height: 6

    # aright = right(3) + cont.aright(40) + iright(4);
    # abottom = bottom(1) + cont.abottom(4) + ibottom(3).
    rb.aright.should eq 47
    rb.abottom.should eq 8
    # aleft/atop of a far-anchored box come from the window far edge:
    # aleft = window.awidth(80) - awidth(10) - aright(47);
    # atop  = window.aheight(24) - aheight(6) - abottom(8).
    # (These read the widget's OWN size — `awidth` on the x axis, `aheight` on
    # the y axis; a swapped size token here would move the box.)
    rb.aleft.should eq 23
    rb.atop.should eq 10
  end

  it "mirrors near- and far-anchored widgets across both axes" do
    _s, cont = make_fixture
    # Same size, mirrored anchoring: left:3 ↔ right:3, top:1 ↔ bottom:1.
    lt = Widget::Box.new parent: cont, left: 3, top: 1, width: 10, height: 6
    rb = Widget::Box.new parent: cont, right: 3, bottom: 1, width: 10, height: 6

    # Container content box (absolute), accounting for the asymmetric insets.
    cl = cont.aleft + cont.ileft
    cr = cont.aleft + cont.awidth - cont.iright
    ct = cont.atop + cont.itop
    cb = cont.atop + cont.aheight - cont.ibottom

    # Point-reflection symmetry: the near widget's inset from the content near
    # edge equals the far widget's inset from the content far edge, and vice
    # versa. A size-token swap in the far-anchored `aleft`/`atop` branch (which
    # divides by the widget's own size) breaks these because width ≠ height.
    (lt.aleft - cl).should eq(cr - (rb.aleft + rb.awidth))
    (cr - (lt.aleft + lt.awidth)).should eq(rb.aleft - cl)
    (lt.atop - ct).should eq(cb - (rb.atop + rb.aheight))
    (cb - (lt.atop + lt.aheight)).should eq(rb.atop - ct)
  end

  it "centers on the correct axis size in the center-anchored branch" do
    _s, cont = make_fixture
    # `aleft`'s center branch pulls back by `awidth // 2`, `atop`'s by
    # `aheight // 2`, each resolving `center` against the parent's matching
    # dimension. With width(10) ≠ height(6) a swapped size or parent-dim token
    # lands the box off its parent's center.
    c = Widget::Box.new parent: cont, left: "center", top: "center",
      width: 10, height: 6

    # A correctly centered widget's geometric center coincides with the parent
    # box center on each axis (the near inset is skipped for centered widgets,
    # so this holds regardless of the asymmetric padding).
    (c.aleft + c.awidth // 2).should eq(cont.aleft + cont.awidth // 2)
    (c.atop + c.aheight // 2).should eq(cont.atop + cont.aheight // 2)
    # Exact resolved origin (locks both the pullback size and the parent-dim
    # reference): center of 40-wide ⇒ 20, minus width/2(5) ⇒ 15; center of
    # 20-tall ⇒ 10, minus height/2(3) ⇒ 7.
    c.aleft.should eq 15
    c.atop.should eq 7
  end
end
