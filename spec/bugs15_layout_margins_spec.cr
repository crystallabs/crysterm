require "./spec_helper"

include Crysterm

# Regression specs for the BUGS15 layout-margin fixes (#66 Form, #67 Grid,
# #73 Flow MoveWidget). Headless harness mirrors spec/bugs15_layout_spec.cr.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def margin(left = 0, top = 0, right = 0, bottom = 0)
  Style.new(margin: Margin.new(left: left, top: top, right: right, bottom: bottom))
end

# BUGS15 #66 — Layout::Form ignored child margins on both axes, so a margined
# label/field was shifted out of its reserved slot by `_get_coords`' near-margin
# shift and overdrew the neighbouring column / next row. The fix reserves each
# child's margin box (width minus mhorizontal, row advance by the tallest margin
# box).
describe "BUGS15 form reserves child margin boxes (fix #66)" do
  it "keeps a left-margined label out of its field's column" do
    s = headless_screen
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 10,
      layout: Layout::Form.new(label_width: 12, horizontal_spacing: 1)
    label = Widget::Box.new parent: form, height: 1, style: margin(left: 2)
    field = Widget::Box.new parent: form, height: 1

    s.repaint

    ll = label.lpos.not_nil!
    fl = field.lpos.not_nil!
    # Pre-fix: label painted xi=2..xl=14 while the field started at xi=13 — a
    # one-column overlap. The label's drawn right edge must stay left of the
    # field's drawn left edge.
    ll.xl.should be < fl.xi
  end

  it "keeps a top-margined row from bleeding into the next row" do
    s = headless_screen
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 10,
      layout: Layout::Form.new(label_width: 12, horizontal_spacing: 1)
    # First row: a label with a top margin.
    l1 = Widget::Box.new parent: form, height: 1, style: margin(top: 1)
    Widget::Box.new parent: form, height: 1
    # Second row, whose slot the margined first row must not overdraw.
    l2 = Widget::Box.new parent: form, height: 1
    Widget::Box.new parent: form, height: 1

    s.repaint

    l1l = l1.lpos.not_nil!
    l2l = l2.lpos.not_nil!
    # Pre-fix: the first row advanced by rh only, so the top-margined first
    # label (yi=1..yl=2) collided with the second row (also near yi=1). The
    # first row's drawn bottom must stay above the second row's top.
    l1l.yl.should be <= l2l.yi
  end

  it "reserves the trailing full-width child's horizontal margin" do
    s = headless_screen
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 10,
      layout: Layout::Form.new(label_width: 12, horizontal_spacing: 1)
    Widget::Box.new parent: form, height: 1
    Widget::Box.new parent: form, height: 1
    # Odd trailing child spans the full width; a right margin must keep it inside.
    trailer = Widget::Box.new parent: form, height: 1, style: margin(left: 2, right: 3)

    s.repaint

    tl = trailer.lpos.not_nil!
    fl = form.lpos.not_nil!
    # Its drawn box must stay within the form's interior, not paint past either
    # edge after the near-margin shift.
    tl.xi.should be >= (fl.xi + form.ileft)
    tl.xl.should be <= (fl.xl - form.iright)
  end
end

# BUGS15 #67 — Layout::Grid ignored child margins: a margined child was shifted
# out of its cell by `_get_coords` and overdrew the adjacent cell (or painted
# past the container for a last-column/row cell). The fix subtracts the margin
# sums from the assigned cell size.
describe "BUGS15 grid reserves child margin boxes (fix #67)" do
  it "keeps a left-margined cell child out of the neighbouring cell" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::Grid.new(columns: 2, spacing: 0)
    a = Widget::Box.new parent: box,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0), style: margin(left: 2)
    b = Widget::Box.new parent: box,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 1)

    s.repaint

    al = a.lpos.not_nil!
    bl = b.lpos.not_nil!
    # Pre-fix: child A painted xi=2..xl=12 while B's cell started at xi=10 —
    # columns 10-11 overdrawn. A's drawn right edge must stay left of B's.
    al.xl.should be <= bl.xi
  end

  it "keeps a top-margined last-row child inside the container's bottom edge" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 4,
      layout: Layout::Grid.new(columns: 1, rows: 1, spacing: 0)
    child = Widget::Box.new parent: box,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0), style: margin(top: 2)

    s.repaint

    cl = child.lpos.not_nil!
    bl = box.lpos.not_nil!
    # Pre-fix: the full-cell height was assigned then shifted down by margin-top,
    # painting past the container's far edge. It must stay inside.
    cl.yl.should be <= (bl.yl - box.ibottom)
  end
end

# BUGS15 #73 — Flow's Overflow::MoveWidget branch was a no-op for non-Window
# containers: the child never repositions itself (its overflow resolves to
# Ignore, never inheriting the container's), so a MoveWidget flow behaved like
# Ignore. The fix translates the overflowing child back into the interior on
# the overflow (vertical) axis.
describe "BUGS15 flow MoveWidget moves an overflowing child back in (fix #73)" do
  it "pulls a bottom-overflowing child up into the container interior" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 10, height: 4,
      layout: Layout::Wrap.new, overflow: :move_widget
    # Two 8x3 children: the second wraps to a new row that would overflow the
    # 4-high interior bottom (yi=3..yl=6 pre-fix).
    Widget::Box.new parent: box, width: 8, height: 3
    second = Widget::Box.new parent: box, width: 8, height: 3

    s.repaint

    sl = second.lpos.not_nil!
    bl = box.lpos.not_nil!
    # Pre-fix: rendered yi=3..yl=6, two rows past the container's yl. After the
    # fix its whole box is translated back inside the interior bottom.
    sl.yl.should be <= (bl.yl - box.ibottom)
    second.top.should eq 1 # interior.height(4) - mvertical(0) - aheight(3)
  end
end
