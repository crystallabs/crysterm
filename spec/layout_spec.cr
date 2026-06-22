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

describe Crysterm::Layout::Grid do
  it "snaps children to uniform columns and wraps on overflow" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 12,
      layout: Layout::Grid.new, overflow: :ignore
    6.times { Widget::Box.new parent: box, width: 8, height: 2 }

    coords = render_children s, box
    # 8-wide columns: 3 fit per 30-wide row (4th would hit 32 > 30), so 2 rows.
    coords.should eq [
      {0, 8, 0, 2}, {8, 16, 0, 2}, {16, 24, 0, 2},
      {0, 8, 2, 4}, {8, 16, 2, 4}, {16, 24, 2, 4},
    ]
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
