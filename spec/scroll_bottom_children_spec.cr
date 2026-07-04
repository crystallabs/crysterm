require "./spec_helper"

include Crysterm

# Regression for `Widget#_scroll_bottom` (and thus `get_scroll_height`) after the
# allocation fix that routes the per-child `_get_coords` through a reused scratch
# `LPos` (`@_scrollb_lpos`) instead of allocating a fresh `LPos` per non-fixed
# child per frame. The scratch is consumed immediately within the reduce, so the
# computed scroll height must be identical to the pre-fix behavior: it reflects
# the bottom-most extent of the (non-fixed) children.

private def sb_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

describe "Widget#_scroll_bottom with children" do
  it "computes scroll height from the bottom-most child extent" do
    s = sb_screen
    box = Widget.new parent: s, top: 0, left: 0, width: 20, height: 5,
      scrollable: true

    # Children extending well past the visible area of the scrollable box.
    Widget.new parent: box, top: 0, left: 0, width: 10, height: 2
    Widget.new parent: box, top: 8, left: 0, width: 10, height: 3

    s.render

    # Bottom-most child ends at row 8 + 3 = 11 (relative to the box interior),
    # so scroll height must be at least that far.
    box.get_scroll_height.should eq 11

    # Stable across repeated renders (memo + scratch reuse must not corrupt it).
    s.render
    box.get_scroll_height.should eq 11
  end

  it "grows scroll height when a deeper child is added" do
    s = sb_screen
    box = Widget.new parent: s, top: 0, left: 0, width: 20, height: 5,
      scrollable: true
    Widget.new parent: box, top: 2, left: 0, width: 10, height: 2
    s.render
    box.get_scroll_height.should eq 4

    Widget.new parent: box, top: 20, left: 0, width: 10, height: 1
    s.render
    box.get_scroll_height.should eq 21
  end
end
