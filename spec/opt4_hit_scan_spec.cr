require "./spec_helper"

include Crysterm

# `Window#widget_at`'s hit scan (`Window#hit_scan`) prunes two kinds of subtree:
# invisible ones, and the ones a *clipping* container's painted rect already
# excludes (O4-24). The clip prune is only sound because `Widget#coords` clips
# every descendant's `lpos` to its `#clip_ancestor`'s viewport — so these specs
# pin both the prune and the one documented escape from it (`fixed`), plus the
# hover memo keyed on `{x, y, renders}` (O4-26).
describe "Window#widget_at clip pruning" do
  it "does not hit a widget scrolled out of its clipping container" do
    s = headless_screen(40, 30)
    c = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      scrollable: true
    c.clickable = true
    # Well past the container's bottom edge: `coords` clips it away entirely,
    # so it paints nothing and claims no cell.
    out = Widget::Box.new parent: c, left: 0, top: 15, width: 10, height: 3
    out.clickable = true
    s.repaint

    out.lpos.should be_nil
    s.widget_at(2, 16).should be_nil
    # The container itself is still hit inside its own viewport.
    s.widget_at(2, 2).should eq c
  end

  it "still hits a partially clipped child on the rows it does paint" do
    s = headless_screen(40, 30)
    c = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      scrollable: true
    c.clickable = true
    child = Widget::Box.new parent: c, left: 0, top: 8, width: 10, height: 6
    child.clickable = true
    s.repaint

    # Rows 8..9 are inside the viewport, rows 10..13 were clipped away.
    s.widget_at(2, 9).should eq child
    s.widget_at(2, 11).should be_nil
  end

  it "prunes an `overflow: Hidden` container the point falls outside of" do
    s = headless_screen(40, 30)
    c = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10
    c.overflow = Overflow::Hidden
    c.clickable = true
    out = Widget::Box.new parent: c, left: 0, top: 15, width: 10, height: 3
    out.clickable = true
    s.repaint

    out.lpos.should be_nil
    s.widget_at(2, 16).should be_nil
  end

  it "keeps hit-testing a `fixed` descendant that escapes the clip" do
    # `Widget#clip_ancestor` exempts a `fixed` widget (border labels, bound
    # scroll bars, background layers) from exactly one *scrollable* clipper, so
    # it paints — and must stay hittable — outside that container's rect. This
    # is the one case the clip prune must not swallow.
    s = headless_screen(40, 30)
    c = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      scrollable: true
    c.clickable = true
    esc = Widget::Box.new parent: c, left: 0, top: 15, width: 10, height: 3
    esc.clickable = true
    esc.fixed = true
    s.repaint

    esc.lpos.should_not be_nil
    s.widget_at(2, 16).should eq esc
  end

  it "finds a `fixed` escapee nested below a non-clipping intermediate" do
    # The exemption is not limited to direct children: nothing between the
    # widget and the scrollable container clips, so the walk hunting escapees
    # has to descend, not just check the container's own children.
    s = headless_screen(40, 30)
    c = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      scrollable: true
    c.clickable = true
    mid = Widget::Box.new parent: c, left: 0, top: 0, width: 20, height: 20
    esc = Widget::Box.new parent: mid, left: 0, top: 15, width: 10, height: 3
    esc.clickable = true
    esc.fixed = true
    s.repaint

    s.widget_at(2, 16).should eq esc
  end

  it "does not resurrect a `fixed` widget below an intervening clipper" do
    # The escapee spends its single exemption on the inner container, so the
    # outer one clips it after all — the hunt is right to stop at a clipper.
    s = headless_screen(40, 30)
    outer = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      scrollable: true
    outer.clickable = true
    inner = Widget::Box.new parent: outer, left: 0, top: 0, width: 20, height: 4,
      scrollable: true
    inner.clickable = true
    esc = Widget::Box.new parent: inner, left: 0, top: 15, width: 10, height: 3
    esc.clickable = true
    esc.fixed = true
    s.repaint

    s.widget_at(2, 16).should be_nil
  end

  it "keeps hitting the z-indexed child inside the clip" do
    # `z_index` does not escape the clip — `coords` clips a layered widget like
    # any other — but it does still out-rank a later tree-order sibling within
    # the container, which the prune must not disturb.
    s = headless_screen(40, 30)
    c = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      scrollable: true
    c.clickable = true
    top = Widget::Box.new parent: c, left: 2, top: 2, width: 10, height: 4
    top.clickable = true
    top.style.z_index = 10
    base = Widget::Box.new parent: c, left: 2, top: 2, width: 10, height: 4
    base.clickable = true
    s.repaint

    s.widget_at(4, 3).should eq top
  end

  it "clips a z-indexed child scrolled out of the container just like a plain one" do
    # Pinned deliberately: a layered subtree composites onto a `Plane` above the
    # base layer, but its geometry still runs through `#clip_ancestor`, so it
    # paints nothing outside its container and is no hit-test candidate there.
    # That is what makes the clip prune exact in the presence of z-index.
    s = headless_screen(40, 30)
    c = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      scrollable: true
    c.clickable = true
    z = Widget::Box.new parent: c, left: 0, top: 15, width: 10, height: 3
    z.clickable = true
    z.style.z_index = 5
    s.repaint

    z.lpos.should be_nil
    s.widget_at(2, 16).should be_nil
  end
end

describe "Window#widget_at hover memo" do
  it "serves a repeated coordinate from the memo without rescanning" do
    s = headless_screen(40, 30)
    b = Widget::Box.new parent: s, left: 2, top: 2, width: 10, height: 4
    b.clickable = true
    s.repaint

    s.widget_at(4, 3).should eq b
    scans = s.hit_scans
    s.widget_at(4, 3).should eq b
    s.hit_scans.should eq scans

    # A different cell is a miss.
    s.widget_at(20, 20)
    s.hit_scans.should eq scans + 1
  end

  it "invalidates the memo when a render has happened since" do
    s = headless_screen(40, 30)
    b = Widget::Box.new parent: s, left: 2, top: 2, width: 10, height: 4
    b.clickable = true
    s.repaint

    s.widget_at(4, 3)
    scans = s.hit_scans
    s.repaint
    s.widget_at(4, 3).should eq b
    s.hit_scans.should eq scans + 1
  end

  it "reflects a widget moved by a re-render rather than the stale memo" do
    s = headless_screen(40, 30)
    b = Widget::Box.new parent: s, left: 2, top: 2, width: 10, height: 4
    b.clickable = true
    s.repaint
    s.widget_at(4, 3).should eq b

    b.top = 20
    s.repaint
    s.widget_at(4, 3).should be_nil
    s.widget_at(4, 21).should eq b
  end

  it "does not serve a `skip:` lookup from — or into — the memo" do
    # The drag path passes `skip:`, whose answer is a different question at the
    # same coordinates; it must neither read nor poison the hover memo.
    s = headless_screen(40, 30)
    under = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10
    under.clickable = true
    over = Widget::Box.new parent: s, left: 2, top: 2, width: 10, height: 4
    over.clickable = true
    s.repaint

    s.widget_at(4, 3).should eq over
    s.widget_at(4, 3, skip: over).should eq under
    s.widget_at(4, 3).should eq over
  end
end
