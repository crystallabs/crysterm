require "./spec_helper"

include Crysterm

# Regression: the transient drag "ghost" (floated under the pointer during a
# transfer drag) must sit under the pointer even when the *screen has padding*.
#
# A top-level widget's `left`/`top` are measured from the screen's content
# origin, so its absolute position is `aleft == screen.ileft + left`. The ghost
# is placed from the pointer's *absolute* coordinates, so the screen padding has
# to be subtracted when computing its `left`/`top` (the reposition drag handler
# already does the equivalent via `Widget#drag_origin`). Before the fix the
# ghost was offset by `ileft`/`itop` from the pointer on a padded screen.
describe "drag ghost on a padded screen" do
  it "floats the ghost directly under the pointer regardless of screen padding" do
    s = Crysterm::Window.new(
      input: IO::Memory.new,
      output: IO::Memory.new,
      error: IO::Memory.new,
      width: 40, height: 20)
    s.padding = Crysterm::Padding.new(3, 2, 0, 0) # left=3, top=2

    source = Widget::Box.new parent: s, left: 5, top: 5, width: 6, height: 3
    source.enable_drag reposition: false # transfer source -> gets a ghost

    px, py = 10, 8
    s.start_drag source, px, py, Crysterm::DragSensor::Mouse

    ghost = s.children.last
    # The ghost floats one cell to the right of the pointer, at the pointer row.
    ghost.aleft.should eq(px + 1)
    ghost.atop.should eq(py)
  end
end
