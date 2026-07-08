require "./spec_helper"

include Crysterm

# Regression spec for BUGS11 #8 (src/widget_interaction.cr).
#
# The default reposition drag captured its grab offset against the
# margin-INCLUSIVE origin (`aleft`/`atop` default to `with_margin: true`), but
# `_get_coords` shifts the drawn box outward by the margin a second time. The
# net effect: dragging a widget that has a CSS/`style.margin` made it jump
# right/down by its own margin on the first motion instead of tracking the
# pointer. The fix grabs against the margin-LESS origin
# (`aleft(with_margin: false)` / `atop(with_margin: false)`) so the round-trip
# through `left=`/`top=` + `_get_coords` is exact.

private def bugs11_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

describe "BUGS11 #8 dragging a margined widget tracks the pointer" do
  it "does not jump right/down by its margin on the first drag motion" do
    s = bugs11_screen
    box = Crysterm::Widget::Box.new(
      parent: s, left: 5, top: 4, width: 10, height: 4,
      draggable: true,
      style: Crysterm::Style.new(margin: Crysterm::Margin.new(left: 3, top: 2, right: 0, bottom: 0)))
    s._render

    start_left = box.left
    start_top = box.top
    start_left.should eq 5
    start_top.should eq 4

    # Grab exactly at the widget's painted top-left corner. `aleft`/`atop`
    # (default `with_margin: true`) is where `_get_coords` actually paints the
    # box, i.e. where the pointer would land when grabbing it.
    x0 = box.aleft
    y0 = box.atop

    data = Crysterm::DragData.new(box)
    session = Crysterm::DragSession.new(box, data, x0, y0, Crysterm::DragSensor::Mouse)

    box.emit Crysterm::Event::DragStart, session

    # Move the pointer one cell right and one cell down.
    session.x = x0 + 1
    session.y = y0 + 1
    box.emit Crysterm::Event::Drag, session

    # The widget must follow the pointer by exactly one cell. With the pre-fix
    # (margin-inclusive) grab offset the offset double-counted the margin, so it
    # jumped to left 9 / top 7 (margin.left+1 / margin.top+1) instead of 6 / 5.
    box.left.should eq 6
    box.top.should eq 5
  end
end
