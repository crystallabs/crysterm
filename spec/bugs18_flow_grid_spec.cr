require "./spec_helper"

include Crysterm

# Regression specs for BUGS18 flow/grid findings: B18-19, B18-20, B18-21,
# B18-24.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# B18-19 — a deferred (z-indexed) shrink-to-fit flow child DRAWS at its shrunk
# content extent, but its `awidth`/`aheight` resolve to the full remaining
# interior. The assigned-geometry fallback for a deferred predecessor used
# `awidth`/`aheight`, so successors of an auto-sized deferred child were
# permanently wrapped (or pushed below the interior) on EVERY frame. Flow now
# reads `occupied_width`/`occupied_height`, which prefer the drawn rect on a
# nil-size axis.
describe "BUGS18 B18-19: Flow uses a deferred auto-sized child's drawn extent" do
  it "chains the successor off a deferred auto-width child's drawn width" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 6,
      layout: Layout::Wrap.new
    a = Widget::Box.new parent: box, content: "hi", height: 1
    a.style.z_index = 1
    b = Widget::Box.new parent: box, width: 12, height: 1

    3.times { s.repaint }

    bl = box.lpos.not_nil!
    al = a.lpos.not_nil!
    # A draws shrunk to its content width, well short of the interior.
    (al.xl - al.xi).should be < 40
    # Pre-fix: A's stretched full-interior awidth anchored the chain, so B
    # wrapped to row 1 on every frame. It must sit flush beside A instead.
    blp = b.lpos.not_nil!
    blp.yi.should eq bl.yi
    blp.xi.should eq al.xl
  ensure
    s.try &.destroy
  end

  it "advances the row cursor by a deferred auto-height child's drawn height" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 6,
      layout: Layout::Wrap.new
    a = Widget::Box.new parent: box, content: "hi", width: 12
    a.style.z_index = 1
    b = Widget::Box.new parent: box, width: 30, height: 1

    3.times { s.repaint }

    bl = box.lpos.not_nil!
    # B wraps below A (12 + 30 > 40). Pre-fix: A's stretched aheight (the
    # whole remaining interior) advanced the row offset to the container
    # bottom, rendering B (and any later row) outside the interior.
    blp = b.lpos.not_nil!
    blp.xi.should eq bl.xi
    blp.yi.should eq bl.yi + 1
  ensure
    s.try &.destroy
  end
end

# B18-20 — the Flow family had no `vacant?` handling: a hidden child inflated
# the row height, indented successors off the assigned-geometry chain,
# inflated UniformGrid's column pitch, and could SkipWidget/StopRendering
# visible siblings. `Flow#arrange` now packs as though a vacant child weren't
# there, matching Layout::Box/Border.
describe "BUGS18 B18-20: Flow engines treat hidden children as vacant" do
  it "does not let a hidden child inflate the row height" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 24, height: 20,
      layout: Layout::Wrap.new
    Widget::Box.new parent: box, width: 8, height: 2
    b = Widget::Box.new parent: box, width: 8, height: 10
    b.visible = false
    Widget::Box.new parent: box, width: 8, height: 2
    Widget::Box.new parent: box, width: 8, height: 2
    e = Widget::Box.new parent: box, width: 8, height: 2

    s.repaint

    bl = box.lpos.not_nil!
    b.lpos.should be_nil
    # A/C/D pack row 0; E wraps to row 1 at the visible row height 2 — not 10,
    # the hidden child's assigned height.
    el = e.lpos.not_nil!
    el.xi.should eq bl.xi
    el.yi.should eq bl.yi + 2
  ensure
    s.try &.destroy
  end

  it "starts the row at the origin when the first child is hidden" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 24, height: 20,
      layout: Layout::Wrap.new
    b = Widget::Box.new parent: box, width: 8, height: 2
    b.visible = false
    c = Widget::Box.new parent: box, width: 8, height: 2

    s.repaint

    # Pre-fix: C chained off the hidden child's assigned awidth (left 8);
    # an HBox in the identical setup yields left 0.
    c.lpos.not_nil!.xi.should eq box.lpos.not_nil!.xi
  ensure
    s.try &.destroy
  end

  it "does not let a hidden wide child set UniformGrid's column pitch" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 10,
      layout: Layout::UniformGrid.new
    Widget::Box.new parent: box, width: 4, height: 2
    b = Widget::Box.new parent: box, width: 20, height: 2
    b.visible = false
    c = Widget::Box.new parent: box, width: 4, height: 2

    s.repaint

    bl = box.lpos.not_nil!
    # Pre-fix: the hidden 20-wide child set @high_width and consumed a row
    # wrap, pushing C to (20, 2). The visible children's pitch is 4.
    clp = c.lpos.not_nil!
    clp.xi.should eq bl.xi + 4
    clp.yi.should eq bl.yi
  ensure
    s.try &.destroy
  end

  it "does not let a hidden overflowing child stop rendering visible successors" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 24, height: 4,
      layout: Layout::Wrap.new, overflow: Overflow::StopRendering
    Widget::Box.new parent: box, width: 8, height: 2
    b = Widget::Box.new parent: box, width: 8, height: 20
    b.visible = false
    c = Widget::Box.new parent: box, width: 8, height: 2

    s.repaint

    bl = box.lpos.not_nil!
    # Pre-fix: the hidden child's assigned extent tripped StopRendering and C
    # never rendered (lpos nil).
    clp = c.lpos.not_nil!
    clp.xi.should eq bl.xi + 8
    clp.yi.should eq bl.yi
  ensure
    s.try &.destroy
  end
end

# B18-21 — with inferred rows (nil `rows`), an explicit hint row origin was
# clamped only to ROW_ORIGIN_CAP, so one child hinted past the interior
# inflated the inferred row count until every innocent sibling's cell divided
# down to zero height and vanished. The origin now clamps to the interior's
# last row, like the declared-rows branch and the column axis.
describe "BUGS18 B18-21: Grid inferred rows clamp an off-grid hint origin" do
  it "keeps auto-flow siblings visible alongside an off-grid hinted child" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 10,
      layout: Layout::Grid.new(columns: 2)
    bad = Widget::Box.new parent: box,
      layout_hint: Layout::Grid::Hint.new(row: 100, column: 0)
    b = Widget::Box.new parent: box
    c = Widget::Box.new parent: box

    s.repaint

    bl = box.lpos.not_nil!
    # The off-grid child keeps its bottom-row sliver...
    badl = bad.lpos.not_nil!
    badl.yi.should eq bl.yi + 9
    (badl.yl - badl.yi).should eq 1
    # ...and the innocent siblings no longer collapse to zero-height cells.
    blp = b.lpos.not_nil!
    blp.yi.should eq bl.yi
    (blp.yl - blp.yi).should eq 1
    clp = c.lpos.not_nil!
    clp.xi.should eq bl.xi + 20
    clp.yi.should eq bl.yi
  ensure
    s.try &.destroy
  end
end

# B18-24 — the B16-22 last-valid-row clamp covered only explicitly-hinted
# children; the auto-flow cursor freely advanced past a declared `rows` and
# the overflow child collapsed to a zero-height cell (lpos nil, unclickable).
# Auto-flow placements are now clamped like the hint pass, stacking overflow
# children into the last row.
describe "BUGS18 B18-24: Grid auto-flow past declared rows stays visible" do
  it "renders the overflowing auto-flow child in the last row" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::Grid.new(columns: 2, rows: 2)
    kids = Array.new(5) { Widget::Box.new parent: box }

    s.repaint

    bl = box.lpos.not_nil!
    # Kids 1-4 fill the declared 2x2 grid as before.
    kids[0].lpos.not_nil!.yi.should eq bl.yi
    kids[3].lpos.not_nil!.yi.should eq bl.yi + 5
    # Kid 5 overflows the declared grid: clamped into the last row (the same
    # visible-stacking tradeoff the hint pass makes) instead of vanishing
    # into a zero-height cell past the bottom edge.
    k5 = kids[4].lpos.not_nil!
    k5.xi.should eq bl.xi
    k5.yi.should eq bl.yi + 5
    (k5.yl - k5.yi).should eq 5
  ensure
    s.try &.destroy
  end
end
