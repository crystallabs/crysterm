require "./spec_helper"

include Crysterm

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# Renders `container` headlessly and returns each child's rendered rectangle as
# `{xi, xl, yi, yl}` tuples (mirrors `spec/layout_spec.cr`).
private def render_children(s, container)
  s._render
  container.children.map do |c|
    l = c.lpos.not_nil!
    {l.xi, l.xl, l.yi, l.yl}
  end
end

# BUGS6 §5.1 — a flex child's cursor advance must use its CLAMPED used size, not
# the raw grow-share. A flex child gets share `s`, but renders at `a_main_size`,
# which `clamp_awidth`/`clamp_aheight` clamps to `[min, max]`. Pre-fix the cursor
# advanced by `s`, so a CSS min/max constraint made the child overlap the next
# child (min > s) or leave a gap and fall short of the far edge (max < s).
describe "BUGS6 Box flex advance honors the child's min/max clamp (fix #1)" do
  it "does not overlap the next child when a flex child has min-width > its share" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 4,
      layout: Layout::HBox.new
    a = Widget::Box.new parent: box, height: 2 # flex, share 15
    Widget::Box.new parent: box, height: 2     # flex, share 15
    # `a`'s share is 15, but its min-width lifts its used width to 20.
    a.min_width = 20

    coords = render_children s, box
    ax, bx = coords[0], coords[1]
    # `a` renders at its clamped width 20 and `b` starts flush after it (28),
    # not overlapped at 15.
    ax.should eq({0, 20, 0, 2})
    bx[0].should eq 20       # b starts after a's *clamped* end, no overlap
    bx[0].should be >= ax[1] # no overlap invariant
  end

  it "leaves no double-counted slot when a flex child has max-width < its share" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 4,
      layout: Layout::HBox.new
    a = Widget::Box.new parent: box, height: 2 # flex, share 15
    Widget::Box.new parent: box, height: 2     # flex, share 15
    # `a`'s share is 15, capped to 8 by max-width. Cursor must advance by 8,
    # so `b` starts at 8 (pre-fix it advanced by 15, leaving a 7-col gap).
    a.max_width = 8

    coords = render_children s, box
    coords[0].should eq({0, 8, 0, 2})
    coords[1][0].should eq 8 # b flush after a's clamped end
  end

  it "keeps the remainder-exact fill for unconstrained flex children (BUGS3 §4)" do
    s = headless_screen
    # Odd interior (11) split between two equal-grow children: the fix must not
    # regress the exact fill — an unconstrained child clamps back to its share.
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 11, height: 4,
      layout: Layout::HBox.new
    Widget::Box.new parent: box, height: 2
    Widget::Box.new parent: box, height: 2

    coords = render_children s, box
    coords.should eq [{0, 5, 0, 2}, {5, 11, 0, 2}]
  end

  it "clamps on the vertical (main) axis too in a VBox with min-height" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 20,
      layout: Layout::VBox.new
    a = Widget::Box.new parent: box, width: 6 # flex, share 10
    Widget::Box.new parent: box, width: 6     # flex, share 10
    a.min_height = 14

    coords = render_children s, box
    # a: rows [0,14); b flush after, starting at 14 (not overlapped at 10).
    coords[0].should eq({0, 6, 0, 14})
    coords[1][2].should eq 14
  end
end

# BUGS6 §5.2 — an over-large `row_span` (the "span to the end" idiom, e.g. 99)
# must not collapse the grid when `rows` is nil. Pre-fix `nrows` was inferred as
# `max(row + row_span)`, so `row_span: 99` inflated the grid to 99 rows, squeezing
# every cell to ~0 and driving `inner_h` negative with any gap. The fix caps the
# inferred row count so a giant span instead spans to the last real row,
# symmetric with how `column_span: 99` spans to the last column.
describe "BUGS6 Grid row_span 'span to the end' does not collapse the grid (fix #2)" do
  it "keeps sane row heights when a child spans to the end (rows nil)" do
    s = headless_screen
    g = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 20,
      layout: Layout::Grid.new(columns: 2, gap: 1)
    # Spanning child in column 0, plus two ordinary children in column 1.
    Widget::Box.new parent: g,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0, row_span: 99, column_span: 1)
    Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 0, column: 1)
    Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 1, column: 1)

    coords = render_children s, g
    sp = coords[0]
    # The spanning cell must have a real, positive height (not collapsed to 0),
    # and reach the grid's full interior height (span to the last row).
    (sp[3] - sp[2]).should be > 0
    sp[2].should eq 0
    sp[3].should eq 20 # spans the full 20-row interior
  end

  it "does not drive cell heights to zero for the non-spanning siblings" do
    s = headless_screen
    g = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 20,
      layout: Layout::Grid.new(columns: 2, gap: 1)
    Widget::Box.new parent: g,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0, row_span: 99)
    Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 0, column: 1)
    Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 1, column: 1)

    coords = render_children s, g
    (coords[1][3] - coords[1][2]).should be > 0 # b has height
    (coords[2][3] - coords[2][2]).should be > 0 # c has height
  end

  it "still honors a modest span that legitimately extends the grid" do
    s = headless_screen
    g = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 20,
      layout: Layout::Grid.new(columns: 2)
    Widget::Box.new parent: g,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0, row_span: 2)
    Widget::Box.new parent: g, layout_hint: Layout::Grid::Hint.new(row: 0, column: 1)

    coords = render_children s, g
    # Two children imply a 2-row grid; `a` spans both rows -> full height 20.
    coords[0][3].should eq 20
  end
end

# BUGS6 §5.3 — the `@flex`/`@filled` latch must release when the user assigns an
# explicit size. Once auto-sized, a child joined `@flex` and stayed flex forever;
# setting `child.width = N` after the first frame was overwritten by a fresh
# grow-share every frame, with no way to convert it back to fixed. The fix tracks
# the last layout-assigned size and reverts the child to fixed once its raw size
# no longer matches.
describe "BUGS6 Box releases a flex child when the user sets an explicit size (fix #3)" do
  it "honors a width set on a previously-flex child on the next frame" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 4,
      layout: Layout::HBox.new
    a = Widget::Box.new parent: box, height: 2 # flex, share 15
    Widget::Box.new parent: box, height: 2     # flex, share 15

    first = render_children s, box
    first.should eq [{0, 15, 0, 2}, {15, 30, 0, 2}]

    # User pins `a` to a fixed width. Pre-fix `a` stayed flex and was re-shared
    # back to 15; the fix keeps it at 6 and gives the leftover to flex `b`.
    a.width = 6
    second = render_children s, box
    second[0].should eq({0, 6, 0, 2})
    second[1].should eq({6, 30, 0, 2}) # b (still flex) absorbs the leftover
  end

  it "releases a stretched (cross-axis) child when an explicit cross size is set" do
    s = headless_screen
    # Default align is Stretch: the layout assigns the cross (height) size and
    # records it in `@filled`, exercising the latch that pre-fix never released.
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::HBox.new
    a = Widget::Box.new parent: box, width: 6 # cross (height) auto -> stretched

    first = render_children s, box
    (first[0][3] - first[0][2]).should eq 10 # stretched to full cross extent

    # Pin the cross size; the child must keep it rather than be re-stretched to
    # the full cross extent by the `@filled` latch on the next frame.
    a.height = 3
    second = render_children s, box
    (second[0][3] - second[0][2]).should eq 3
  end
end
