require "./spec_helper"

include Crysterm

# Regression specs for the BUGS16 layout overflow batch:
#
# * B16-20 — `Layout::Box` clamps a per-child `Hint#stretch` factor before the
#   grow accumulation/share math, and does that math in `Int64`, so a
#   pathological (huge or negative) factor can't raise `OverflowError` in
#   `#measure`/`#place`.
# * B16-23 — `Layout::Grid` clamps `columns`/a declared `rows` to the interior
#   extent, and runs the spacing/fence math in `Int64`, so a pathological
#   `columns`/`rows`/`spacing` value can't raise `OverflowError` mid-render.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS16 B16-20 Box clamps extreme stretch factors" do
  it "does not raise OverflowError with two near-MAX/large stretch factors" do
    screen = headless_screen
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new
    Widget::Box.new parent: box, layout_hint: Layout::Box::Hint.new(stretch: Int32::MAX)
    Widget::Box.new parent: box, layout_hint: Layout::Box::Hint.new(stretch: 2)
    screen._render # pre-fix: OverflowError at the cumulative share math
  end

  it "does not raise OverflowError with a single Int32::MAX stretch factor" do
    screen = headless_screen
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new
    Widget::Box.new parent: box, layout_hint: Layout::Box::Hint.new(stretch: Int32::MAX)
    screen._render # pre-fix: OverflowError at `@avail * @grow_seen`
  end

  it "treats a negative stretch as zero share, not the 1-default" do
    screen = headless_screen
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new
    a = Widget::Box.new parent: box, layout_hint: Layout::Box::Hint.new(stretch: -5)
    b = Widget::Box.new parent: box, layout_hint: Layout::Box::Hint.new(stretch: 1)
    screen._render
    a.awidth.should eq 0
    b.awidth.should eq 30
  end

  it "keeps an ordinary stretch distribution intact (no regression)" do
    screen = headless_screen
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new
    a = Widget::Box.new parent: box, layout_hint: Layout::Box::Hint.new(stretch: 1)
    b = Widget::Box.new parent: box, layout_hint: Layout::Box::Hint.new(stretch: 2)
    screen._render
    a.awidth.should eq 10
    b.awidth.should eq 20
  end
end

describe "BUGS16 B16-23 Grid clamps extreme columns/rows/spacing" do
  it "does not raise OverflowError for columns: Int32::MAX plus an off-grid hint" do
    screen = headless_screen w: 30, h: 9
    g = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 9,
      layout: Layout::Grid.new(columns: Int32::MAX)
    Widget::Box.new parent: g,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 999_999_999)
    screen._render # pre-fix: OverflowError in Layout.fence
  end

  it "does not raise OverflowError for rows: Int32::MAX with spacing" do
    screen = headless_screen w: 30, h: 9
    g = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 9,
      layout: Layout::Grid.new(columns: 2, rows: Int32::MAX, spacing: 2)
    Widget::Box.new parent: g
    screen._render # pre-fix: OverflowError at the inner_h computation
  end

  it "does not raise OverflowError for huge columns, rows, and spacing together" do
    screen = headless_screen w: 30, h: 9
    g = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 9,
      layout: Layout::Grid.new(columns: Int32::MAX, rows: Int32::MAX, spacing: Int32::MAX)
    Widget::Box.new parent: g
    screen._render
  end

  it "keeps an ordinary grid layout intact (no regression)" do
    screen = headless_screen w: 30, h: 9
    g = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 9,
      layout: Layout::Grid.new(columns: 3)
    a = Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 0, column: 0)
    b = Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 0, column: 1)
    screen._render
    al = a.lpos.not_nil!
    bl = b.lpos.not_nil!
    (al.xl - al.xi).should eq 10
    (bl.xi).should eq 10
  end
end
