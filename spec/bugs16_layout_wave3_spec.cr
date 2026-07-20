require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 wave-3 layout findings: B16-21, B16-22, B16-24.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# B16-21 — `Form#add_row` appended unconditionally, assuming an even child
# count. With a blessed trailing odd child (a separator/button row) the new
# pair was split across rows: the separator consumed the new label as its
# "field" and the field landed alone full-width. The pair is now inserted
# BEFORE the trailing child, which stays trailing.
describe "BUGS16 B16-21: Form#add_row with a trailing odd child" do
  it "inserts the new pair before the separator, keeping it trailing and full-width" do
    s = headless_screen
    form_layout = Layout::Form.new
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 10,
      layout: form_layout

    f1 = Widget::Box.new height: 1
    form_layout.add_row "Name", f1
    sep = Widget::Box.new parent: form, height: 1, content: "-" * 10

    f2 = Widget::Box.new height: 1
    form_layout.add_row "Age", f2

    # Pair inserted before the separator; separator still trailing.
    form.children.last.should eq sep
    form.children[2].content.should eq "Age"
    form.children[3].should eq f2

    s.repaint

    # Row 0: Name/f1. Row 1: Age/f2. Row 2: separator, full interior width.
    fl = form.lpos.not_nil!
    f2.lpos.not_nil!.yi.should eq fl.yi + 1
    sp = sep.lpos.not_nil!
    sp.yi.should eq fl.yi + 2
    (sp.xl - sp.xi).should eq 30
  ensure
    s.try &.destroy
  end

  it "keeps the plain append path for an even form" do
    s = headless_screen
    form_layout = Layout::Form.new
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 10,
      layout: form_layout

    f1 = Widget::Box.new height: 1
    form_layout.add_row("Name", f1).should eq f1
    form.children.size.should eq 2
    form.children[1].should eq f1
  ensure
    s.try &.destroy
  end
end

# B16-22 — with a declared `rows`, a hint row origin past the grid collapsed
# to a zero-height cell (the child rendered nowhere), while the column axis
# clamps an off-grid origin to the last column and stays visible.
describe "BUGS16 B16-22: Grid clamps an off-grid row origin like the column axis" do
  it "renders a row-overflowing hinted child in the last row" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 9,
      layout: Layout::Grid.new(columns: 3, rows: 3)
    child = Widget::Box.new parent: box,
      layout_hint: Layout::Grid::Hint.new(row: 5, column: 0)
    control = Widget::Box.new parent: box,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 5)

    s.repaint

    bl = box.lpos.not_nil!
    # Column axis (pre-existing behavior): clamped into the last column.
    cl = control.lpos.not_nil!
    cl.xi.should eq bl.xi + 20
    # Row axis (the fix): clamped into the last row instead of vanishing.
    lp = child.lpos.not_nil!
    lp.yi.should eq bl.yi + 6
    (lp.yl - lp.yi).should eq 3
  ensure
    s.try &.destroy
  end
end

# B16-24 — a deferred (z-indexed) flow child's `lpos` holds the PREVIOUS
# frame's rect during `#arrange` (it is only refreshed at plane compositing),
# so successors chained off it lagged one frame behind any geometry change.
# The chain now falls through to the assigned-geometry branch for a deferred
# predecessor.
describe "BUGS16 B16-24: Flow does not chain off a deferred child's stale lpos" do
  it "places the successor against the deferred child's CURRENT size" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 8,
      layout: Layout::Wrap.new
    a = Widget::Box.new parent: box, width: 5, height: 2
    a.style.z_index = 1
    b = Widget::Box.new parent: box, width: 5, height: 2

    s.repaint
    bl = box.lpos.not_nil!
    b.lpos.not_nil!.xi.should eq bl.xi + 5

    a.width = 10
    s.repaint
    # Pre-fix: B stayed at the stale right edge (xi + 5) for this frame and
    # only healed one render later.
    b.lpos.not_nil!.xi.should eq bl.xi + 10

    s.repaint
    b.lpos.not_nil!.xi.should eq bl.xi + 10 # stable thereafter
  ensure
    s.try &.destroy
  end
end
