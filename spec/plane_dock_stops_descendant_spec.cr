require "./spec_helper"

include Crysterm

# A z-indexed widget is deferred to a compositing `Plane` and painted above the
# base layer (see `Screen#composite_planes`). Its line-drawing border rows must
# dock on the plane's OWN buffer — before it composites down — so an overlay's
# borders join one another but never join to the base content the overlay floats
# over. That routing happens in `Widget#register_dock_stops`, which sends a
# widget's border rows to `Screen#_plane_dock_stops` (plane-local) instead of
# `Screen#_dock_stops` (base) while a plane is being painted.
#
# Before the fix the gate was the widget's own `@compositing` flag, which is set
# ONLY on the layer root. A bordered *descendant* of a z-indexed widget paints
# into the plane just the same (its root redirected `screen.lines` to the plane
# buffer for the whole subtree) but has `@compositing == false`, so its border
# rows leaked onto the BASE `_dock_stops`. The base `#_dock` then joined that
# child's border to the content under the overlay — the stray junction plane
# docking is meant to avoid. The fix gates on the screen's `compositing_layers?`,
# true for the whole subtree, so descendants dock within the plane too.
private def pds_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 40, height: 20)
end

describe "Widget#register_dock_stops (layer descendants)" do
  it "routes a bordered descendant of a z-indexed widget to the plane, not the base" do
    s = pds_screen
    s.alloc

    # A z-indexed (layer) container with a line border, holding a bordered child.
    # The container is the ONLY top-level widget, and it is deferred to a plane —
    # so the base `_dock_stops` must end the frame EMPTY: every bordered widget in
    # play (root and child) lives in the plane.
    outer = Widget::Box.new(parent: s, left: 5, top: 5, width: 12, height: 8,
      style: Style.new(border: true))
    outer.style.z_index = 10
    Widget::Box.new(parent: outer, left: 1, top: 1, width: 8, height: 4,
      style: Style.new(border: true))

    s._render

    # The child's border rows must NOT have leaked onto the base docking set.
    s._dock_stops.empty?.should be_true
    # And the plane stops carry the layer's border rows (root + child).
    s._plane_dock_stops.empty?.should be_false
  end
end
