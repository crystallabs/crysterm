require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 finding #95 (src/window_mouse.cr):
#
# The armed (press-and-hold) drag path used to commit a Click on ANY button's
# release and destroy the arm, ignoring the recorded arming button. It now
# gates the release on the arming button (mirroring handle_active_drag /
# handle_mouse_captor), and refuses to let a different button's press clobber
# a pending arm.

private def ab_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    default_quit_keys: false)
end

private def ab_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def ab_press(s, x, y, button = ::Tput::Mouse::Button::Left)
  s.dispatch_mouse ab_mouse(::Tput::Mouse::Action::Down, x, y, button)
end

private def ab_up(s, x, y, button = ::Tput::Mouse::Button::None)
  s.dispatch_mouse ab_mouse(::Tput::Mouse::Action::Up, x, y, button)
end

private def ab_move(s, x, y)
  s.dispatch_mouse ab_mouse(::Tput::Mouse::Action::Move, x, y, ::Tput::Mouse::Button::None)
end

describe "BUGS15 #95: armed drag path gates on the arming button" do
  it "does not commit a Click (nor drop the arm) on a foreign button's release over the armed widget" do
    s = ab_screen
    w = Widget::Box.new parent: s, left: 0, top: 0, width: 8, height: 4, draggable: true
    clicks = 0
    w.on(Crysterm::Event::Click) { clicks += 1 }
    s._render

    # LMB press arms the drag on W (arming button = Left).
    ab_press s, 3, 1

    # An RMB release over W must NOT emit a Click and must leave the arm intact.
    ab_up s, 3, 1, ::Tput::Mouse::Button::Right
    clicks.should eq(0)

    # The still-pending LMB arm can now start a drag on motion.
    ab_move s, 5, 2
    s.drag_session.should_not be_nil
    s.drag_session.not_nil!.source.should eq w
    s.drag_session.not_nil!.sensor.mouse?.should be_true
  end

  it "still emits a Click on the arming button's own release (no motion)" do
    s = ab_screen
    w = Widget::Box.new parent: s, left: 0, top: 0, width: 8, height: 4, draggable: true
    clicks = 0
    w.on(Crysterm::Event::Click) { clicks += 1 }
    s._render

    ab_press s, 3, 1                           # LMB arms
    ab_up s, 3, 1, ::Tput::Mouse::Button::Left # LMB release over W -> Click
    clicks.should eq(1)
    s.drag_session.should be_nil
  end

  it "treats a buttonless (legacy) release as the arming button's release" do
    s = ab_screen
    w = Widget::Box.new parent: s, left: 0, top: 0, width: 8, height: 4, draggable: true
    clicks = 0
    w.on(Crysterm::Event::Click) { clicks += 1 }
    s._render

    ab_press s, 3, 1                           # LMB arms
    ab_up s, 3, 1, ::Tput::Mouse::Button::None # buttonless up -> Click
    clicks.should eq(1)
  end

  it "does not let a different button's press overwrite a pending arm" do
    s = ab_screen
    w = Widget::Box.new parent: s, left: 0, top: 0, width: 8, height: 4, draggable: true
    clicks = 0
    w.on(Crysterm::Event::Click) { clicks += 1 }
    s._render

    ab_press s, 3, 1                               # LMB arms (arming button = Left)
    ab_press s, 4, 1, ::Tput::Mouse::Button::Right # RMB press must NOT re-arm to Right

    # A subsequent LMB motion still promotes to a drag (arm survived as Left).
    ab_move s, 6, 2
    s.drag_session.should_not be_nil
    s.drag_session.not_nil!.source.should eq w

    # And the RMB press never produced a click on the draggable widget.
    clicks.should eq(0)
  end
end
