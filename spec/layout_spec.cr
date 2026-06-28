require "./spec_helper"

include Crysterm

private def headless_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

# Renders `container` headlessly (the public `Screen#render` only *schedules* a
# render via the loop fiber, which never runs in a one-shot spec) and returns
# each child's rendered rectangle as `{xi, xl, yi, yl}` tuples.
private def render_children(s, container)
  s._render
  container.children.map do |c|
    l = c.lpos.not_nil!
    {l.xi, l.xl, l.yi, l.yl}
  end
end

# Behavior lock for the child-arranging layout engines under `Crysterm::Layout`.
describe Crysterm::Layout::HBox do
  it "lays children left-to-right, sharing leftover width among flex children" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new(gap: 1)
    Widget::Box.new parent: box, width: 6, height: 3
    Widget::Box.new parent: box, height: 3 # flexible width
    Widget::Box.new parent: box, width: 8, height: 3

    coords = render_children s, box
    # flex width = (30 - 6 - 8 - 1 gap*2) / 1 = 14; gaps of 1 between each.
    coords.should eq [{0, 6, 0, 3}, {7, 21, 0, 3}, {22, 30, 0, 3}]
  end

  it "keeps flex sizing stable across re-renders" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new(gap: 1)
    Widget::Box.new parent: box, width: 6, height: 3
    Widget::Box.new parent: box, height: 3
    Widget::Box.new parent: box, width: 8, height: 3

    first = render_children s, box
    second = render_children s, box
    second.should eq first
  end
end

describe Crysterm::Layout::VBox do
  it "lays children top-to-bottom, sharing leftover height among flex children" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 12,
      layout: Layout::VBox.new
    Widget::Box.new parent: box, width: 10, height: 2
    Widget::Box.new parent: box, width: 10 # flexible height
    Widget::Box.new parent: box, width: 10, height: 3

    coords = render_children s, box
    # flex height = (12 - 2 - 3) / 1 = 7
    coords.should eq [{0, 10, 0, 2}, {0, 10, 2, 9}, {0, 10, 9, 12}]
  end
end

describe Crysterm::Layout::UniformGrid do
  it "snaps children to uniform columns and wraps on overflow" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 12,
      layout: Layout::UniformGrid.new, overflow: :ignore
    6.times { Widget::Box.new parent: box, width: 8, height: 2 }

    coords = render_children s, box
    # 8-wide columns: 3 fit per 30-wide row (4th would hit 32 > 30), so 2 rows.
    coords.should eq [
      {0, 8, 0, 2}, {8, 16, 0, 2}, {16, 24, 0, 2},
      {0, 8, 2, 4}, {8, 16, 2, 4}, {16, 24, 2, 4},
    ]
  end

  it "ignores layout-excluded chrome when sizing the uniform column" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 12,
      layout: Layout::UniformGrid.new, overflow: :ignore
    # A full-width excluded layer (e.g. a background-image) must not widen the
    # uniform column and collapse the grid to a single column.
    Widget::Box.new(parent: box, width: 30, height: 12).layout_excluded = true
    cells = Array.new(3) { Widget::Box.new parent: box, width: 8, height: 2 }

    s._render
    cells.map(&.lpos.not_nil!.xi).should eq [0, 8, 16]
  end
end

describe Crysterm::Layout::Masonry do
  it "flows children left-to-right and wraps to a new row on overflow" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 12,
      layout: Layout::Masonry.new, overflow: :ignore
    Widget::Box.new parent: box, width: 12, height: 3
    Widget::Box.new parent: box, width: 12, height: 3 # overflows row -> wraps

    coords = render_children s, box
    coords[0].should eq({0, 12, 0, 3})
    # Second box doesn't fit beside the first (12 + 12 > 20), so it wraps to a
    # new row at the left edge.
    coords[1].should eq({0, 12, 3, 6})
  end
end

describe Crysterm::Layout::Border do
  it "docks edges (top/bottom span width, left/right span remaining height) and fills center" do
    s = headless_screen
    b = Widget::Box.new parent: s, left: 0, top: 0, width: 40, height: 12,
      layout: Layout::Border.new
    Widget::Box.new parent: b, height: 1, layout_hint: Layout::Border::Hint.new(:top)
    Widget::Box.new parent: b, height: 1, layout_hint: Layout::Border::Hint.new(:bottom)
    Widget::Box.new parent: b, width: 10, layout_hint: Layout::Border::Hint.new(:left)
    Widget::Box.new parent: b # center (no hint)

    coords = render_children s, b
    coords.should eq [
      {0, 40, 0, 1},   # top, full width
      {0, 40, 11, 12}, # bottom, full width
      {0, 10, 1, 11},  # left, remaining height
      {10, 40, 1, 11}, # center fills the rest
    ]
  end

  it "clamps oversized edges to the remaining space (no negative or overlapping regions)" do
    s = headless_screen
    # A header and footer that together (4 + 4) exceed the 6-row interior. Without
    # clamping, the footer's `y1 - ch` ran back over the header (rows 2..3 doubly
    # owned) and the center was handed a negative `y1 - y0` height (-2). Each edge
    # must take only what remains: header rows 0..3, footer the last 2 rows (4..5),
    # and the center collapses to zero height — never negative, never overlapping.
    b = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 6,
      layout: Layout::Border.new
    top = Widget::Box.new parent: b, height: 4, layout_hint: Layout::Border::Hint.new(:top)
    bottom = Widget::Box.new parent: b, height: 4, layout_hint: Layout::Border::Hint.new(:bottom)
    center = Widget::Box.new parent: b # center

    s._render
    tl = top.lpos.not_nil!
    {tl.yi, tl.yl}.should eq({0, 4}) # header takes the first 4 rows
    bl = bottom.lpos.not_nil!
    {bl.yi, bl.yl}.should eq({4, 6}) # footer clamped to the remaining 2 rows
    bl.yi.should be >= tl.yl         # no overlap between header and footer
    center.height.should eq 0        # squeezed-out center collapses to 0, not -2
  end
end

describe Crysterm::Layout::Stack do
  it "renders only the current child (filling the interior) and suppresses the rest" do
    s = headless_screen
    st = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 6,
      layout: Layout::Stack.new(1)
    3.times { Widget::Box.new parent: st }

    s._render
    st.children[0].lpos.should be_nil
    st.children[2].lpos.should be_nil
    l = st.children[1].lpos.not_nil!
    {l.xi, l.xl, l.yi, l.yl}.should eq({0, 20, 0, 6})
  end

  it "indexes #current among arrangeable children, skipping layout-excluded chrome" do
    s = headless_screen
    st = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 6,
      layout: Layout::Stack.new(1)
    # A layout-excluded layer (e.g. a background-image) placed before the pages
    # must not occupy a page slot: #current still counts the real pages only.
    bg = Widget::Box.new parent: st, width: 20, height: 6
    bg.layout_excluded = true
    pages = Array.new(3) { Widget::Box.new parent: st }

    s._render
    bg.lpos.should be_nil       # excluded chrome: not arranged by the page pass
    pages[0].lpos.should be_nil # page 0 suppressed
    pages[2].lpos.should be_nil # page 2 suppressed
    pages[1].lpos.not_nil!      # current 1 -> the 2nd real page, not raw child 2
  end
end

describe Crysterm::Layout::Grid do
  it "places spanning children and auto-flows the rest into free cells" do
    s = headless_screen
    g = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::Grid.new(columns: 3)
    Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 0, col: 0, col_span: 2)
    4.times { Widget::Box.new parent: g }

    coords = render_children s, g
    # cells are 10 wide, 5 tall (2 rows). #0 spans cols 0-1; the four auto cells
    # fill (0,2), (1,0), (1,1), (1,2).
    coords.should eq [
      {0, 20, 0, 5}, {20, 30, 0, 5},
      {0, 10, 5, 10}, {10, 20, 5, 10}, {20, 30, 5, 10},
    ]
  end

  it "fills a non-evenly-divisible interior, giving the remainder to the last cell" do
    s = headless_screen
    # 32 wide / 3 cols = 10 r2: a single floored cell_w (10) left the right two
    # columns blank (last col ended at 30, not 32). 8 tall / 3 rows = 2 r2 left
    # the bottom row short likewise. Cumulative fences fill the whole interior.
    g = Widget::Box.new parent: s, left: 0, top: 0, width: 32, height: 8,
      layout: Layout::Grid.new(columns: 3, rows: 3)
    9.times { Widget::Box.new parent: g }

    coords = render_children s, g
    # Columns carve 32 into 10/11/11 (fences 0,10,21,32); rows carve 8 into
    # 2/3/3 (fences 0,2,5,8). The right column reaches x=32 and the bottom row
    # reaches y=8 — no blank gutter.
    coords.should eq [
      {0, 10, 0, 2}, {10, 21, 0, 2}, {21, 32, 0, 2},
      {0, 10, 2, 5}, {10, 21, 2, 5}, {21, 32, 2, 5},
      {0, 10, 5, 8}, {10, 21, 5, 8}, {21, 32, 5, 8},
    ]
  end

  it "clamps an off-grid span (e.g. col_span to the end) to the interior edge" do
    s = headless_screen
    # 3 cols, gap 2 over a 34-wide interior: inner_w = 34 - 2*2 = 30, carved
    # 10/10/10 (fences 0,10,20,30). A cell with an oversized col_span ("span to
    # the end") must reach exactly the interior's right edge (x1 == 34), not
    # overshoot it by the phantom gaps of the off-grid columns.
    g = Widget::Box.new parent: s, left: 0, top: 0, width: 34, height: 6,
      layout: Layout::Grid.new(columns: 3, rows: 1, gap: 2)
    Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 0, col: 0, col_span: 99)

    coords = render_children s, g
    # Spans cols 0..2: x0=0, x1=30 + 2 internal gaps = width 34; right edge 34.
    coords.should eq [{0, 34, 0, 6}]
  end
end

describe Crysterm::Layout::Form do
  it "lays label/field pairs in rows and spans a trailing odd child" do
    s = headless_screen
    f = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 8,
      layout: Layout::Form.new(label_width: 8)
    5.times { Widget::Box.new parent: f, height: 1 }

    coords = render_children s, f
    coords.should eq [
      {0, 8, 0, 1}, {9, 30, 0, 1}, # row 0: label (w8), field (fills, after gap 1)
      {0, 8, 1, 2}, {9, 30, 1, 2}, # row 1
      {0, 30, 2, 3},               # trailing child spans full width
    ]
  end
end

describe Crysterm::Layout::Wrap do
  it "wraps without gravitation (new-row children share the row top)" do
    s = headless_screen
    wp = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10,
      layout: Layout::Wrap.new, overflow: :ignore
    Widget::Box.new parent: wp, width: 12, height: 3
    Widget::Box.new parent: wp, width: 12, height: 3

    coords = render_children s, wp
    coords.should eq [{0, 12, 0, 3}, {0, 12, 3, 6}]
  end

  it "does not chain a flow child off a layout-excluded layer (e.g. background-image)" do
    s = headless_screen
    wp = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::Wrap.new, overflow: :ignore
    # A `background-image` layer is a layout_excluded child that the flow skips
    # but that carries a real (out-of-band-rendered) lpos. `get_last` must skip
    # it: otherwise the next flow child chains its left edge off the layer's
    # rect (here xl=10) instead of starting at the row's left edge.
    bg = Widget::Box.new parent: wp, width: 10, height: 2
    bg.layout_excluded = true
    bg.lpos = Crysterm::LPos.new(xi: 0, xl: 10, yi: 0, yl: 2)
    item = Widget::Box.new parent: wp, width: 8, height: 2

    s._render
    item.lpos.not_nil!.xi.should eq 0
  end

  it "ignores a layout-excluded layer when measuring a wrapped row's height" do
    s = headless_screen
    wp = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 12,
      layout: Layout::Wrap.new, overflow: :ignore
    # Full-interior background-image layer: layout_excluded, but carrying a real
    # (out-of-band-rendered) full-height lpos. The row-height ("tallest") scan in
    # `Flow#flow_place` must skip it; otherwise its 12-row height inflates the
    # first row's height and shoves the wrapped child to top=12 (off-screen)
    # instead of top=3, just below the real first-row child.
    bg = Widget::Box.new parent: wp, width: 20, height: 12
    bg.layout_excluded = true
    bg.lpos = Crysterm::LPos.new(xi: 0, xl: 20, yi: 0, yl: 12)
    Widget::Box.new parent: wp, width: 12, height: 3
    second = Widget::Box.new parent: wp, width: 12, height: 3 # wraps to row 2

    s._render
    second.lpos.not_nil!.yi.should eq 3
  end
end

describe "Crysterm::Layout::Box flex" do
  it "distributes leftover space by per-child grow factor" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 4,
      layout: Layout::HBox.new
    Widget::Box.new parent: box, height: 2, layout_hint: Layout::Box::Hint.new(grow: 1)
    Widget::Box.new parent: box, height: 2, layout_hint: Layout::Box::Hint.new(grow: 2)

    coords = render_children s, box
    # 30 split 1:2 -> 10 and 20.
    coords.should eq [{0, 10, 0, 2}, {10, 30, 0, 2}]
  end

  it "distributes the rounding remainder so flex children fill the interior exactly" do
    s = headless_screen
    # Two equal-grow children over an odd interior width (11). A per-child
    # `width // 2` floors each to 5, leaving the 11th column blank at the right
    # edge; cumulative rounding gives the last flex child the leftover so the
    # children meet flush at the interior's right edge.
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 11, height: 4,
      layout: Layout::HBox.new
    Widget::Box.new parent: box, height: 2 # flexible width
    Widget::Box.new parent: box, height: 2 # flexible width

    coords = render_children s, box
    coords.should eq [{0, 5, 0, 2}, {5, 11, 0, 2}]
  end

  it "justifies fixed children along the main axis" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 4,
      layout: Layout::HBox.new(justify: Layout::Box::Justify::Center)
    Widget::Box.new parent: box, width: 8, height: 2
    Widget::Box.new parent: box, width: 8, height: 2

    coords = render_children s, box
    # 16 used of 30 -> 14 leftover, 7 lead.
    coords.should eq [{7, 15, 0, 2}, {15, 23, 0, 2}]
  end

  it "space-between lands the last child flush against the far edge on an odd leftover" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 31, height: 4,
      layout: Layout::HBox.new(justify: Layout::Box::Justify::SpaceBetween)
    Widget::Box.new parent: box, width: 8, height: 2
    Widget::Box.new parent: box, width: 8, height: 2
    Widget::Box.new parent: box, width: 8, height: 2

    coords = render_children s, box
    # 24 used of 31 -> 7 leftover over 2 gaps. A floored `7 // 2 == 3` gap left
    # the last child ending at 30 (one short of 31); cumulative carving (gaps 3
    # then 4) puts it flush at 31.
    coords.should eq [{0, 8, 0, 2}, {11, 19, 0, 2}, {23, 31, 0, 2}]
  end
end

describe "Crysterm::Layout flow StopRendering" do
  it "clears the lpos of every child left unrendered after an overflow stop" do
    s = headless_screen
    # 20 wide so each 12-wide child wraps to its own row. Frame 1 is tall enough
    # (3 rows) for all three to render, so each gets a real lpos.
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 3,
      layout: Layout::Wrap.new, overflow: Crysterm::Overflow::StopRendering
    a = Widget::Box.new parent: box, width: 12, height: 1
    b = Widget::Box.new parent: box, width: 12, height: 1
    c = Widget::Box.new parent: box, width: 12, height: 1

    s._render
    # All three rendered, so the later children carry a live rectangle.
    a.lpos.should_not be_nil
    b.lpos.should_not be_nil
    c.lpos.should_not be_nil

    # Frame 2: shrink to a single visible row. Now `a` fits, `b` wraps onto an
    # overflowing row and trips StopRendering, and `c` is never reached. The
    # stop must clear the stale rectangles of *both* unrendered children, not
    # just the one that overflowed — otherwise `c` keeps frame-1's lpos and
    # stays clickable/focusable at a ghost position.
    box.height = 1
    s._render

    a.lpos.should_not be_nil
    b.lpos.should be_nil
    c.lpos.should be_nil
  end
end
