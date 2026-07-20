require "./spec_helper"

include Crysterm

# Regression specs for the BUGS17 layout spacing batch:
#
# * B17-10 — `Layout::Box` clamps its `#spacing` against the live main extent
#   (in `#measure`, stashed for `#place`), so a pathological (huge or negative)
#   `spacing` can't overflow the checked-`Int32` gap product / cursor
#   accumulation and crash the render fiber (the class B16-23 fixed for Grid).
# * B17-11 — `Layout::Form` clamps `#horizontal_spacing`/`#vertical_spacing`
#   against the live interior at the top of `#arrange`, so a pathological value
#   can't overflow `lw + hs` or the `y += ... + vs` row advance.
# * B17-09 — `Layout::Masonry` gravitation anchors a wrapping child to a
#   deferred (z-indexed) above-child's CURRENT geometry, not its stale
#   previous-frame `lpos`.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

describe "BUGS17 B17-10 Box clamps extreme spacing" do
  it "does not raise OverflowError with Int32::MAX spacing and two children" do
    screen = headless_screen
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new(spacing: Int32::MAX)
    Widget::Box.new parent: box, width: 5, height: 1
    Widget::Box.new parent: box, width: 5, height: 1
    screen._render # pre-fix: OverflowError at the `@cursor` accumulation in place
  end

  it "does not raise OverflowError with Int32::MAX spacing and three children" do
    screen = headless_screen
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new(spacing: Int32::MAX)
    Widget::Box.new parent: box, width: 5, height: 1
    Widget::Box.new parent: box, width: 5, height: 1
    Widget::Box.new parent: box, width: 5, height: 1
    screen._render # pre-fix: OverflowError at the `gaps` product in measure
  end

  it "does not raise (and does not over-allocate) with negative spacing" do
    screen = headless_screen
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new(spacing: -1000)
    a = Widget::Box.new parent: box
    b = Widget::Box.new parent: box
    screen._render
    # Negative spacing clamps to 0: the two flex children split the interior
    # exactly, no overlap and no over-allocation past the 30-wide interior.
    a.awidth.should eq 15
    b.awidth.should eq 15
  end

  it "keeps an ordinary spacing distribution intact (no regression)" do
    screen = headless_screen
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 30, height: 5,
      layout: Layout::HBox.new(spacing: 2)
    a = Widget::Box.new parent: box
    b = Widget::Box.new parent: box
    screen._render
    # 30 - one 2-cell gap = 28, split evenly.
    a.awidth.should eq 14
    b.awidth.should eq 14
  end
end

describe "BUGS17 B17-11 Form clamps extreme spacing" do
  it "does not raise OverflowError with Int32::MAX horizontal_spacing" do
    screen = headless_screen
    form = Widget::Box.new parent: screen, left: 0, top: 0, width: 60, height: 30,
      layout: Layout::Form.new(horizontal_spacing: Int32::MAX)
    Widget::Box.new parent: form, height: 1, content: "Name"
    Widget::Box.new parent: form, height: 1
    screen._render # pre-fix: OverflowError at `lw + @horizontal_spacing`
  end

  it "does not raise OverflowError with Int32::MAX vertical_spacing" do
    screen = headless_screen
    form = Widget::Box.new parent: screen, left: 0, top: 0, width: 60, height: 30,
      layout: Layout::Form.new(vertical_spacing: Int32::MAX)
    Widget::Box.new parent: form, height: 1, content: "Name"
    Widget::Box.new parent: form, height: 1
    screen._render # pre-fix: OverflowError at the `y += ... + @vertical_spacing` advance
  end

  it "does not raise with negative horizontal and vertical spacing" do
    screen = headless_screen
    form = Widget::Box.new parent: screen, left: 0, top: 0, width: 60, height: 30,
      layout: Layout::Form.new(horizontal_spacing: -50, vertical_spacing: -50)
    Widget::Box.new parent: form, height: 1, content: "Name"
    Widget::Box.new parent: form, height: 1
    screen._render
  end
end

describe "BUGS17 B17-09 Masonry gravitation uses a deferred child's current geometry" do
  it "anchors a gravitating child to the grown z-indexed child's new bottom edge" do
    screen = headless_screen w: 20, h: 12
    box = Widget::Box.new parent: screen, left: 0, top: 0, width: 20, height: 12,
      layout: Layout::Masonry.new
    a = Widget::Box.new parent: box, width: 12, height: 3
    a.style.z_index = 1 # composited on its own plane -> deferred during arrange
    b = Widget::Box.new parent: box, width: 12, height: 3

    screen._render
    bl = box.lpos.not_nil!
    # B wraps below A (12 + 12 > 20) and gravitates flush under A's 3-tall edge.
    b.lpos.not_nil!.yi.should eq bl.yi + 3

    a.height = 5
    screen._render
    # Pre-fix: B glued to A's STALE 3-tall previous-frame bottom edge for this
    # frame and only healed one render later. Post-fix: it anchors on A's
    # assigned geometry (height 5) immediately.
    b.lpos.not_nil!.yi.should eq bl.yi + 5
  end
end
