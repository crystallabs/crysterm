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
    cells.map { |c| c.lpos.not_nil!.xi }.should eq [0, 8, 16]
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
end
