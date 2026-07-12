require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 findings #28, #61, #62, #64, #65
# (src/window_mouse.cr, src/window_drag.cr):
#
# #28      — a wheel over a disabled widget must never reach (or scroll) the
#            widget itself (a disabled Dial/Slider/ScrollBar used to mutate its
#            own value on scroll); the scroll routes to a scrollable ancestor.
# #61/#64  — starting a new drag while another gesture is in flight (e.g. a
#            mouse drag promoted while a keyboard-sensor drag is live) must tear
#            the old session down with DragEnd/DragLeave — and must NOT lose the
#            new drag's arming button while doing so.
# #62      — the keyboard lift branch refuses a disabled widget, mirroring the
#            mouse arm gate.
# #65      — a discrete (two-click) drag commits only on the ARMING button's
#            press; a stray other-button tap is swallowed, not committed.

private def bm_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    default_quit_keys: false)
end

private def bm_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def bm_press(s, x, y, button = ::Tput::Mouse::Button::Left)
  s.dispatch_mouse bm_mouse(::Tput::Mouse::Action::Down, x, y, button)
end

private def bm_move(s, x, y)
  s.dispatch_mouse bm_mouse(::Tput::Mouse::Action::Move, x, y, ::Tput::Mouse::Button::None)
end

private def bm_wheel(s, x, y, up = true)
  s.dispatch_mouse bm_mouse(up ? ::Tput::Mouse::Action::WheelUp : ::Tput::Mouse::Action::WheelDown, x, y, ::Tput::Mouse::Button::None)
end

private def bm_key(char : Char, key : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, key
end

describe "BUGS15 #28: disabled widget takes no wheel Event::Mouse" do
  it "does not deliver a wheel to a disabled widget's own Event::Mouse handler" do
    s = bm_screen
    w = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 4
    w.clickable = true
    wheeled = 0
    w.on(Crysterm::Event::Mouse) { |e| wheeled += 1 if e.action.wheel_up? || e.action.wheel_down? }
    s._render

    # Enabled: the wheel reaches the widget.
    bm_wheel s, 3, 1
    wheeled.should eq(1)

    # Disabled: the wheel must never reach (or act on) the widget itself.
    w.state = Crysterm::WidgetState::Disabled
    bm_wheel s, 3, 1
    wheeled.should eq(1) # unchanged
  end

  it "does not scroll a disabled scrollable widget itself on the wheel" do
    s = bm_screen
    panel = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 10
    # Scrollable child whose content extends well past its viewport (a tall
    # inner spacer), so a delivered wheel WOULD scroll it.
    child = Widget::Box.new parent: panel, left: 0, top: 0, width: 10, height: 4, scrollable: true
    Widget::Box.new parent: child, left: 0, top: 50, width: 2, height: 2
    child.state = Crysterm::WidgetState::Disabled
    scrolled = 0
    child.on(Event::Scroll) { scrolled += 1 }
    s._render

    bm_wheel s, 2, 1, up: false
    scrolled.should eq(0) # the disabled widget did not scroll itself
    child.get_scroll.should eq(0)
  end

  it "still lets a scrollable ancestor take the wheel over a disabled child" do
    s = bm_screen
    # Scrollable ancestor with content past its viewport.
    panel = Widget::Box.new parent: s, left: 0, top: 0, width: 20, height: 6, scrollable: true
    Widget::Box.new parent: panel, left: 0, top: 50, width: 2, height: 2
    # Disabled child inside the viewport — the actual hit target.
    child = Widget::Box.new parent: panel, left: 0, top: 0, width: 10, height: 2
    child.clickable = true
    wheeled = 0
    child.on(Crysterm::Event::Mouse) { |e| wheeled += 1 if e.action.wheel_up? || e.action.wheel_down? }
    child.state = Crysterm::WidgetState::Disabled
    panel_scrolled = 0
    panel.on(Event::Scroll) { panel_scrolled += 1 }
    s._render

    bm_wheel s, 2, 1, up: false
    wheeled.should eq(0)        # the disabled child never saw the wheel
    panel_scrolled.should eq(1) # ...but its scrollable ancestor did
  end
end

describe "BUGS15 #61/#64: start_drag cancels an in-flight session cleanly" do
  it "ends a live keyboard drag (DragEnd + target DragLeave) when a mouse drag starts" do
    s = bm_screen
    a = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3, draggable: true, keys: true
    b = Widget::Box.new parent: s, left: 20, top: 0, width: 6, height: 3, draggable: true
    a.focus

    a_ended = false
    a_dropped = true
    a.on(Event::DragEnd) { |e| a_ended = true; a_dropped = e.dropped? }
    # A keyboard drag targets the focused widget, i.e. `a` itself on lift.
    a_left = 0
    a.on(Event::DragLeave) { a_left += 1 }

    s._drag_key_handled(bm_key(' ')).should be_true
    s.dragging.not_nil!.source.should eq a

    # Mouse-drag `b`: arm on press, promote on motion -> start_drag cancels a.
    bm_press s, 21, 1
    bm_move s, 23, 2

    a_ended.should be_true    # the replaced source got its DragEnd
    a_dropped.should be_false # reported as not dropped (cancelled)
    a_left.should be >= 1     # its DragEnter'd target got a DragLeave
    s.dragging.not_nil!.source.should eq b
    s.dragging.not_nil!.sensor.mouse?.should be_true
  end

  it "preserves the new mouse drag's arming button across the old-session cancel (#61 verifier)" do
    # drag_cancel nils @_drag_button; start_drag must snapshot/restore it so a
    # stray non-arming button can't commit the new drop (gesture_end_button?
    # treats a nil armed button as matching anything).
    s = bm_screen
    a = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3, draggable: true, keys: true
    b = Widget::Box.new parent: s, left: 20, top: 0, width: 6, height: 3, draggable: true
    a.focus

    s._drag_key_handled(bm_key(' ')).should be_true # keyboard drag on a
    bm_press s, 21, 1                               # arm mouse (Left) on b
    bm_move s, 23, 2                                # promote -> b drag (armed Left)
    s.dragging.not_nil!.source.should eq b

    # A stray Right-button press must NOT commit the (continuous) mouse drag.
    bm_press s, 24, 2, ::Tput::Mouse::Button::Right
    s.dragging.should_not be_nil # still dragging b

    # The arming (Left) button's release commits it.
    s.dispatch_mouse bm_mouse(::Tput::Mouse::Action::Up, 24, 2, ::Tput::Mouse::Button::None)
    s.dragging.should be_nil
  end
end

describe "BUGS15 #62: keyboard drag sensor refuses a disabled widget" do
  it "does not lift a focused-but-disabled draggable on Space" do
    s = bm_screen
    box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4, draggable: true, keys: true
    box.focus
    box.state = Crysterm::WidgetState::Disabled # disabled while focused (stays focused)

    s._drag_key_handled(bm_key(' ')).should be_false
    s.dragging.should be_nil
  end
end

describe "BUGS15 #65: discrete drag commits only on the arming button" do
  it "swallows a stray other-button press and drops only on the arming button" do
    s = bm_screen
    s.drag_two_click = true

    source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
    source.enable_drag reposition: false
    source.on(Event::DragStart) { |e| e.data["text/plain"] = "p" }
    target = Widget::Box.new parent: s, left: 40, top: 0, width: 10, height: 4
    target.on(Event::DragOver, &.accept)
    dropped = nil
    target.on(Event::Drop) { |e| dropped = e.data["text/plain"] }

    bm_press s, 1, 1 # Left press lifts (arming button = Left)
    s.dragging.should_not be_nil

    # A stray Right-button press over the target must be swallowed, not commit.
    bm_press s, 44, 1, ::Tput::Mouse::Button::Right
    dropped.should be_nil
    s.dragging.should_not be_nil

    # The arming (Left) button's press commits the discrete drop.
    bm_press s, 44, 1
    dropped.should eq("p")
    s.dragging.should be_nil
  end
end
