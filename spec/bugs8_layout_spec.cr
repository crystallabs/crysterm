require "./spec_helper"

include Crysterm

# Regression specs for the BUGS8 Box-layout margin fixes. The render pipeline
# shifts every laid child outward by its near margin (`coords`), and a
# Box-assigned size is a fixed `Int32` that never folds its margin in (unlike an
# auto fill). The `Box`/HBox/VBox engine referenced child margins nowhere, so a
# margined child overflowed (Stretch cross axis) or overlapped its siblings
# (main axis). Same headless harness as `bugs6_layout_spec.cr`.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def render_children(s, container)
  s.repaint
  container.children.map do |c|
    l = c.lpos.not_nil!
    {l.xi, l.xl, l.yi, l.yl}
  end
end

describe "BUGS8 Box main-axis packing reserves child margins (fix #6)" do
  it "does not overlap the next child when a child carries a main-axis margin" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 40, height: 4,
      layout: Layout::HBox.new
    Widget::Box.new parent: box, width: 10, height: 2
    # Middle child has a 3-col left margin.
    Widget::Box.new parent: box, width: 10, height: 2,
      style: Style.new(margin: Margin.new(left: 3, top: 0, right: 0, bottom: 0))
    Widget::Box.new parent: box, width: 10, height: 2

    coords = render_children s, box
    a, b, c = coords[0], coords[1], coords[2]
    a.should eq({0, 10, 0, 2})
    b.should eq({13, 23, 0, 2}) # shifted right 3 by its margin
    c.should eq({23, 33, 0, 2}) # flush after b — pre-fix it was {20,30,..}, overlapping b
    b[0].should be >= a[1]      # no-overlap invariant
    c[0].should be >= b[1]
  end
end

describe "BUGS8 Box Stretch align reserves cross-axis margins (fix #5)" do
  it "shrinks the stretched size so a margined child stays inside the interior" do
    s = headless_screen
    box = Widget::Box.new parent: s, left: 0, top: 0, width: 30, height: 10,
      layout: Layout::VBox.new # cross axis is width
    # No explicit width → stretched; margin 2 on every side.
    Widget::Box.new parent: box, height: 3, style: Style.new(margin: 2)

    coords = render_children s, box
    rect = coords[0]
    # Inset 2 on the near sides, 26 wide (30 - 2 - 2), 3 tall — fully inside the
    # interior [0,30). Pre-fix the width stayed 30 and xl overflowed to 32.
    rect.should eq({2, 28, 2, 5})
    rect[1].should be <= box.awidth.not_nil! # right edge does not clip past interior
  end
end
