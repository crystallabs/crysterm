require "./spec_helper"

include Crysterm

# Regression specs for the BUGS12 layout fixes. Headless harness mirrors
# spec/bugs11_layout_margin_spec.cr / spec/bugs8_layout_spec.cr.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# BUGS12 #36 — Stack layout suppressed non-current pages with `skip el`, which
# clears only the page's own `lpos`. A hidden page's descendants kept their stale
# rects, so `Window#widget_at` still hit-tested them. The fix uses `skip_subtree`
# (as the base collapsed-interior path and `Flow#arrange` already do).
describe "BUGS12 stack layout clears hidden pages' descendants (fix #36)" do
  it "nils a hidden page's child lpos instead of leaving it stale/hittable" do
    s = headless_screen
    stack = Layout::Stack.new
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: stack

    page0 = Widget::Box.new parent: box
    child0 = Widget::Box.new parent: page0, top: 1, left: 1, width: 5, height: 3
    page1 = Widget::Box.new parent: box
    child1 = Widget::Box.new parent: page1, top: 1, left: 1, width: 5, height: 3

    # Show page 0: its descendant paints and gets a live rect.
    stack.current = 0
    s._render
    child0.lpos.should_not be_nil

    # Switch to page 1: page 0 is now hidden. Its descendant must be cleared,
    # not left with the stale rect from the previous frame.
    stack.current = 1
    s._render

    child0.lpos.should be_nil     # hidden page's descendant no longer hittable
    child1.lpos.should_not be_nil # newly-shown page's descendant paints
  end
end

# BUGS12 #37 — Border/dock layout reserved each edge child's margin box when
# advancing the working rect, but placed bottom/right children with `top = y1 - ch`
# / `left = x1 - cw`. `_get_coords`' near-anchor `shift_margin` then drew the box
# past the region's far edge by the child's near margin. The fix subtracts the
# child's margin total in the placement, mirroring the advance.
describe "BUGS12 border layout accounts for margin shift on far edges (fix #37)" do
  it "keeps a top-margined bottom child within the container's interior" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::Border.new

    footer = Widget::Box.new parent: box, height: 2,
      layout_hint: Layout::Border::Hint.new(:bottom),
      style: Style.new(margin: Margin.new(left: 0, top: 1, right: 0, bottom: 0))
    Widget::Box.new parent: box # center

    s._render

    fl = footer.lpos.not_nil!
    bl = box.lpos.not_nil!

    # Pre-fix the footer was placed at y1-ch then shifted down by its top margin,
    # painting one row past the interior bottom; post-fix it stays inside.
    fl.yl.should be <= (bl.yl - box.ibottom)
  end

  it "keeps a left-margined right child within the container's interior" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      layout: Layout::Border.new

    sidebar = Widget::Box.new parent: box, width: 4,
      layout_hint: Layout::Border::Hint.new(:right),
      style: Style.new(margin: Margin.new(left: 1, top: 0, right: 0, bottom: 0))
    Widget::Box.new parent: box # center

    s._render

    rl = sidebar.lpos.not_nil!
    bl = box.lpos.not_nil!

    # Pre-fix the sidebar was placed at x1-cw then shifted right by its left
    # margin, painting one column past the interior right edge; post-fix it stays.
    rl.xl.should be <= (bl.xl - box.iright)
  end
end
