require "./spec_helper"

include Crysterm

# Regression specs for the BUGS7 "Input & Event Dispatch" fixes.
#
# 1. `window_mouse.cr` must not deliver `Event::Mouse`/`Event::Click` to a
#    *disabled* widget under the pointer. Only the click-to-focus branch was
#    gated before, so a disabled Button still fired `Event::Press` and a
#    disabled CheckBox still toggled. The keyboard path is safe because a
#    disabled widget can't hold focus; the mouse path now mirrors that.
#
# 2. A press over a normal draggable *arms* a reposition drag and emits no
#    `Event::Click`; when a later motion promotes it to a drag the running
#    click-count must be reset (as the two-click branch already does), so a
#    later quick click on the same spot isn't read as a double-click.

private def bugs7_screen(w = 40, h = 20)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h)
end

private def down_at(s, x, y)
  s.dispatch_mouse(::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, x, y, source: :test))
end

private def move_at(s, x, y)
  s.dispatch_mouse(::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::Left, x, y, source: :test))
end

private def up_at(s, x, y)
  s.dispatch_mouse(::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Up, ::Tput::Mouse::Button::Left, x, y, source: :test))
end

describe "BUGS7 disabled widget does not activate on a mouse click" do
  it "does not emit Event::Press for a disabled Button clicked" do
    s = bugs7_screen
    btn = Widget::Button.new parent: s, top: 2, left: 2, width: 10, height: 3
    btn.state = WidgetState::Disabled
    s._render

    pressed = 0
    btn.on(Crysterm::Event::Press) { pressed += 1 }

    down_at s, btn.aleft + 1, btn.atop + 1
    pressed.should eq 0
  end

  it "still emits Event::Press for an enabled Button (no regression)" do
    s = bugs7_screen
    btn = Widget::Button.new parent: s, top: 2, left: 2, width: 10, height: 3
    s._render

    pressed = 0
    btn.on(Crysterm::Event::Press) { pressed += 1 }

    down_at s, btn.aleft + 1, btn.atop + 1
    pressed.should eq 1
  end

  it "does not toggle a disabled CheckBox clicked" do
    s = bugs7_screen
    cb = Widget::CheckBox.new parent: s, top: 2, left: 2, width: 12, height: 1
    cb.state = WidgetState::Disabled
    s._render

    was = cb.checked?
    down_at s, cb.aleft, cb.atop
    cb.checked?.should eq was # unchanged
  end
end

describe "BUGS7 click-count is not inflated by an arm→drag promotion" do
  it "reads a fresh count on a later click after a motion-promoted drag" do
    s = bugs7_screen

    box = Widget::Box.new(
      parent: s, top: 2, left: 2, width: 12, height: 4,
      draggable: true, style: Style.new(border: true))

    other = Widget::Box.new(
      parent: s, top: 12, left: 2, width: 12, height: 3,
      style: Style.new(border: true))
    other.clickable = true

    s._render

    # Press over the draggable arms the drag (no Click yet), then a motion on a
    # different cell promotes it to a real drag — the arming press is consumed
    # and must not feed the running click-count.
    down_at s, box.aleft + 2, box.atop + 1
    move_at s, box.aleft + 5, box.atop + 2
    s.click_count.should eq 0
    up_at s, box.aleft + 5, box.atop + 2 # end the drag session

    counts = [] of Int32
    other.on(Crysterm::Event::Click) { counts << s.click_count }
    down_at s, other.aleft + 2, other.atop + 1

    counts.last.should eq 1 # a single click, not a double
  end
end
