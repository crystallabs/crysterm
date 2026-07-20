require "./spec_helper"

include Crysterm

# A z-indexed widget is deferred to a compositing `Plane` and painted above the
# base layer (see `Window#composite_planes`). Its line-drawing border rows must
# dock on the plane's own buffer, before it composites down, so an overlay's
# borders join each other but never the base content underneath. Routing
# happens in `Widget#register_dock_stops`, sending border rows to
# `Window#_plane_dock_stops` (plane-local) instead of `Window#_dock_stops`
# (base) while a plane is being painted.
#
# Before the fix the gate was `@compositing`, set only on the layer root. A
# bordered descendant paints into the plane too (root redirected
# `screen.lines` for the whole subtree) but has `@compositing == false`, so its
# border rows leaked onto the base `_dock_stops`, joining the child's border to
# content under the overlay. Fix gates on `compositing_layers?` instead, true
# for the whole subtree.
private def pds_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 40, height: 20)
end

describe "Widget#register_dock_stops (layer descendants)" do
  it "routes a bordered descendant of a z-indexed widget to the plane, not the base" do
    s = pds_screen
    s.alloc

    # A z-indexed (layer) container with a line border, holding a bordered
    # child. The container is the only top-level widget and is deferred to a
    # plane, so base `_dock_stops` must end the frame empty: every bordered
    # widget (root and child) lives in the plane.
    outer = Widget::Box.new(parent: s, left: 5, top: 5, width: 12, height: 8,
      style: Style.new(border: true))
    outer.style.z_index = 10
    Widget::Box.new(parent: outer, left: 1, top: 1, width: 8, height: 4,
      style: Style.new(border: true))

    s.repaint

    # The child's border rows must not have leaked onto the base docking set.
    s._dock_stops.empty?.should be_true
    # Plane stops carry the layer's border rows (root + child).
    s._plane_dock_stops.empty?.should be_false
  end
end
