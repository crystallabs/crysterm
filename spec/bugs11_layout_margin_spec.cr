require "./spec_helper"

include Crysterm

# Regression specs for the BUGS11 layout-margin fixes. Headless harness mirrors
# spec/bugs5_layout_spec.cr / spec/bugs8_layout_spec.cr / spec/bugs9_layout_geom_spec.cr.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# BUGS11 #25 — Flow wrap fit-check omits the child's own left margin, so a
# margined child whose margin box straddles the right edge is kept on the row and
# painted past the interior instead of wrapping. The render pipeline shifts the
# drawn box right by `mleft` without shrinking a fixed width, so the horizontal
# fit test must include `mleft`.
describe "BUGS11 flow wrap fit-check includes the child's left margin (fix #25)" do
  it "wraps a left-margined Wrap child instead of painting it past the right edge" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 9, height: 6,
      layout: Layout::Wrap.new, overflow: Overflow::Ignore

    mg = Margin.new(left: 1, top: 0, right: 0, bottom: 0)
    c0 = Widget::Box.new parent: box, width: 4, height: 2, style: Style.new(margin: mg)
    c1 = Widget::Box.new parent: box, width: 4, height: 2, style: Style.new(margin: mg)

    s.repaint

    bl = box.lpos.not_nil!
    l0 = c0.lpos.not_nil!
    l1 = c1.lpos.not_nil!

    # c0 sits on the first row, shifted right by its own left margin (xi = 1).
    l0.yi.should eq(bl.yi)

    # c1's margin box (left=5, mleft=1, awidth=4 -> cols 6..10) would straddle the
    # 9-wide interior's right edge; pre-fix it stayed on row 0 and painted to
    # xl=10, one column past the interior. Post-fix it wraps to the second row.
    l1.yi.should be > l0.yi  # wrapped to a new row
    l1.xl.should be <= bl.xl # no longer painted past the right edge
  end
end

# BUGS11 #26 — Border layout carved regions by border-box size only, ignoring the
# edge child's near margin, so a margined edge child (drawn shifted by its margin)
# overlapped the neighboring region. The carve must reserve the child's margin box.
describe "BUGS11 border layout reserves the edge child's margin box (fix #26)" do
  it "keeps a top-margined header from overlapping the center region" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::Border.new

    header = Widget::Box.new parent: box, height: 2,
      layout_hint: Layout::Border::Hint.new(:top),
      style: Style.new(margin: Margin.new(left: 0, top: 1, right: 0, bottom: 0))
    center = Widget::Box.new parent: box

    s.repaint

    hl = header.lpos.not_nil!
    cl = center.lpos.not_nil!

    # The header is drawn shifted down by its top margin (rows 1..3). Pre-fix the
    # center region started at row 2 (advanced by height 2 only) and overdrew the
    # header's last row; post-fix the region starts below the header's margin box.
    hl.yl.should be <= cl.yi
  end
end
