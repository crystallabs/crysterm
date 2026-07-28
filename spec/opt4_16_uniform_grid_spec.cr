require "./spec_helper"

include Crysterm

# Regression specs for OPT4 O4-16: `UniformGrid#before_flow` resolved each
# occupying child's `awidth` in its widest-child scan, then `Flow#flow_place`'s
# placement fit check (layout/flow.cr) resolved the very same child's `awidth`
# again. The fix caches the scan's per-child values in `UniformGrid` and reuses
# them via `Flow#cached_awidth`, which the `Wrap`/`Masonry` siblings (no
# `#before_flow` scan) never override, so they still resolve `el.awidth` fresh
# at the fit check exactly as before.

# Counts calls to `#awidth` made with the default (un-rendered) argument — the
# form both `UniformGrid#before_flow`'s scan and `Flow#flow_place`'s fit check
# use (`el.awidth`). `#base_render` also calls `awidth(true)` on every widget
# every frame (widget_rendering.cr) to read its own rendered size; that's
# unrelated per-widget render bookkeeping, not the double layout-resolution
# O4-16 is about, so it's excluded from the count.
private class AwidthCountingBox < Widget::Box
  property awidth_calls = 0

  def awidth(rendered = false) : Int32
    @awidth_calls += 1 unless rendered
    super
  end
end

describe "OPT4 O4-16: UniformGrid awidth caching" do
  it "positions children identically to a hand-computed uniform-column layout" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 10,
      layout: Layout::UniformGrid.new
    a = Widget::Box.new parent: box, width: 6, height: 2
    b = Widget::Box.new parent: box, width: 10, height: 2
    c = Widget::Box.new parent: box, width: 6, height: 2

    s.repaint

    bl = box.lpos.not_nil!
    al = a.lpos.not_nil!
    bpl = b.lpos.not_nil!
    cl = c.lpos.not_nil!

    # Widest child (B, 10) sets the uniform column pitch; every child snaps to
    # it regardless of its own width, all on row 0 (3 * 10 = 30 == interior).
    al.xi.should eq bl.xi
    al.yi.should eq bl.yi
    bpl.xi.should eq bl.xi + 10
    bpl.yi.should eq bl.yi
    cl.xi.should eq bl.xi + 20
    cl.yi.should eq bl.yi
  ensure
    s.try &.destroy
  end

  it "resolves each child's un-rendered awidth fewer than twice per frame" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 10,
      layout: Layout::UniformGrid.new
    children = [
      AwidthCountingBox.new(parent: box, width: 6, height: 2),
      AwidthCountingBox.new(parent: box, width: 10, height: 2),
      AwidthCountingBox.new(parent: box, width: 6, height: 2),
    ]

    s.repaint

    total_calls = children.sum(&.awidth_calls)
    # Pre-fix this was up to one scan call plus one fit-check call per child;
    # the cache collapses the fit-check call to zero. Bounded loosely (not
    # pinned to the exact per-child count) so the assertion tracks the
    # single-vs-double-resolution shape of the fix rather than its precise
    # internal call graph.
    total_calls.should be < 2 * children.size
  ensure
    s.try &.destroy
  end
end

describe "OPT4 O4-16: Wrap/Masonry fallback (no before_flow cache)" do
  it "Wrap still wraps children onto rows at their natural widths" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::Wrap.new
    a = Widget::Box.new parent: box, width: 12, height: 2
    b = Widget::Box.new parent: box, width: 12, height: 2
    c = Widget::Box.new parent: box, width: 5, height: 2

    s.repaint

    bl = box.lpos.not_nil!
    al = a.lpos.not_nil!
    bpl = b.lpos.not_nil!
    cl = c.lpos.not_nil!

    # A fills row 0 at its natural width.
    al.xi.should eq bl.xi
    al.yi.should eq bl.yi

    # B (12 wide) doesn't fit beside A (12 + 12 = 24 > 20 interior) -> wraps.
    bpl.xi.should eq bl.xi
    bpl.yi.should eq bl.yi + 2

    # C (5 wide) fits beside B on row 1 (12 + 5 = 17 <= 20).
    cl.xi.should eq bl.xi + 12
    cl.yi.should eq bl.yi + 2
  ensure
    s.try &.destroy
  end

  it "Masonry still lays out a small run of children correctly" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::Masonry.new
    a = Widget::Box.new parent: box, width: 12, height: 3
    b = Widget::Box.new parent: box, width: 12, height: 2
    c = Widget::Box.new parent: box, width: 6, height: 1

    s.repaint

    bl = box.lpos.not_nil!
    al = a.lpos.not_nil!
    bpl = b.lpos.not_nil!
    cl = c.lpos.not_nil!

    al.xi.should eq bl.xi
    al.yi.should eq bl.yi

    # B doesn't fit beside A -> wraps to a new row beneath it.
    bpl.xi.should eq bl.xi
    bpl.yi.should eq bl.yi + 3

    # C fits beside B.
    cl.xi.should eq bl.xi + 12
    cl.yi.should eq bl.yi + 3
  ensure
    s.try &.destroy
  end
end
