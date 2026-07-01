require "./spec_helper"

include Crysterm

# `Window#widget_at` resolves the topmost widget under the pointer and must
# follow paint order, which `z-index` overrides on top of tree order: a widget
# declaring `style.z_index` is deferred to a compositing `Plane` and painted
# above the whole base layer (see `Window#composite_planes`), regardless of
# tree position.
#
# Before the fix, `widget_at` returned the last tree-order match ignoring
# z-index, so a non-z-indexed widget added after (and overlapping) a
# z-indexed one would steal the click.
private def waz_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 40, height: 20)
end

describe "Window#widget_at (z-index)" do
  it "hits the z-indexed widget painted on top, not the later tree-order one" do
    s = waz_screen

    # `top` is added first but carries a z-index, so it composites above the
    # base layer. `base` is added later and overlaps it; tree order alone
    # would wrongly pick `base`.
    top = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    top.clickable = true
    top.style.z_index = 10
    base = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    base.clickable = true

    # A point inside both boxes resolves to the visually-topmost (z-indexed) one.
    s.widget_at(8, 7).should eq top
  end

  it "still breaks ties within the same layer by tree order (last wins)" do
    s = waz_screen
    a = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    a.clickable = true
    b = Widget::Box.new parent: s, left: 5, top: 5, width: 10, height: 6
    b.clickable = true

    # No z-index anywhere: "last painted wins" behavior.
    s.widget_at(8, 7).should eq b
  end
end
