require "./spec_helper"

include Crysterm

# Regression specs for the BUGS13 layout batch:
#
# * S10 — flipping `layout_excluded = true` at runtime clears the subtree's
#   last-rendered rects (mirroring `Layout#skip_subtree`), so the invisible
#   widget stops taking clicks/hovers at its stale rect.
# * S16 — `Layout::Grid` clamps degenerate hints before bookkeeping: a
#   `row_span/column_span: Int32::MAX` must not insert 2^31 occupancy tuples per
#   frame (multi-second stall/hang), and `row: Int32::MAX` must not raise
#   `OverflowError` in the row inference.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS13 S10 layout_excluded=true clears stale subtree rects" do
  it "clears lpos of the widget and its descendants on a false->true flip" do
    screen = headless_screen
    parent = Widget::Box.new parent: screen, left: 0, top: 0, width: 40, height: 20
    child = Widget::Box.new parent: parent, left: 0, top: 0, width: 10, height: 5
    grand = Widget::Box.new parent: child, left: 0, top: 0, width: 4, height: 2
    screen._render
    child.lpos.should_not be_nil
    grand.lpos.should_not be_nil

    child.layout_excluded = true
    child.lpos.should be_nil
    grand.lpos.should be_nil

    # The child pass keeps skipping it, so the rects stay cleared.
    screen._render
    child.lpos.should be_nil
    grand.lpos.should be_nil
  end

  it "clears the rects under a layout engine too" do
    screen = headless_screen
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 40, height: 10,
      layout: Layout::HBox.new
    a = Widget::Box.new parent: box, height: 5
    b = Widget::Box.new parent: box, height: 5
    screen._render
    a.lpos.should_not be_nil

    a.layout_excluded = true
    a.lpos.should be_nil
    screen._render
    a.lpos.should be_nil
    b.lpos.should_not be_nil # sibling keeps rendering (and now gets the space)
  end

  it "flipping back to false resumes rendering" do
    screen = headless_screen
    parent = Widget::Box.new parent: screen, left: 0, top: 0, width: 40, height: 20
    child = Widget::Box.new parent: parent, left: 0, top: 0, width: 10, height: 5
    screen._render
    child.layout_excluded = true
    screen._render
    child.lpos.should be_nil

    child.layout_excluded = false
    screen._render
    child.lpos.should_not be_nil
  end
end

describe "BUGS13 S16 Grid clamps extreme spans and rows" do
  it "arranges promptly with row_span/column_span Int32::MAX (no per-frame stall)" do
    screen = headless_screen
    g = Widget::Box.new parent: screen, left: 0, top: 0, width: 40, height: 20,
      layout: Layout::Grid.new(columns: 3)
    a = Widget::Box.new parent: g,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0, row_span: Int32::MAX, column_span: Int32::MAX)
    b = Widget::Box.new parent: g # auto-flow

    started = Time.instant
    screen._render # pre-fix: ~2^31 Set inserts per span axis (effectively a hang)
    (Time.instant - started).should be < 5.seconds

    a.lpos.should_not be_nil
    b.lpos.should_not be_nil
    # The spanning child still "spans to the end" horizontally.
    al = a.lpos.not_nil!
    (al.xl - al.xi).should eq 40
  end

  it "does not raise OverflowError for row: Int32::MAX" do
    screen = headless_screen
    g = Widget::Box.new parent: screen, left: 0, top: 0, width: 40, height: 20,
      layout: Layout::Grid.new(columns: 2)
    Widget::Box.new parent: g,
      layout_hint: Layout::Grid::Hint.new(row: Int32::MAX, column: 0)
    Widget::Box.new parent: g # auto-flow
    screen._render            # pre-fix: OverflowError in the checked `p[1] + p[3]`/`p[1] + 1`
  end

  it "keeps ordinary spans and occupancy intact (no regression)" do
    screen = headless_screen
    g = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 20,
      layout: Layout::Grid.new(columns: 3)
    a = Widget::Box.new parent: g,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0, row_span: 2, column_span: 2)
    b = Widget::Box.new parent: g # auto-flow: must skip a's 2x2 block -> (0, 2)
    screen._render

    al = a.lpos.not_nil!
    bl = b.lpos.not_nil!
    # Two rows inferred; a spans both -> full interior height.
    (al.yl - al.yi).should eq 20
    (al.xl - al.xi).should eq 20 # 2 of 3 columns
    # b sits in the third column of row 0, not inside a's block.
    bl.xi.should eq al.xl
    bl.yi.should eq 0
  end

  it "still lets an over-large span mean 'span to the end' (BUGS6 semantics)" do
    screen = headless_screen
    g = Widget::Box.new parent: screen, left: 0, top: 0, width: 20, height: 20,
      layout: Layout::Grid.new(columns: 2, spacing: 1)
    a = Widget::Box.new parent: g,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0, row_span: 99, column_span: 1)
    Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 0, column: 1)
    Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 1, column: 1)
    screen._render

    al = a.lpos.not_nil!
    al.yi.should eq 0
    al.yl.should eq 20 # spans the full interior height
  end
end
