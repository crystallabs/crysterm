require "./spec_helper"

include Crysterm

# Removing a widget from its `Screen` must drop any transient mouse-interaction
# pointer aimed into the removed subtree, the same way `Screen#remove` already
# rewinds keyboard focus out of it (see `screen_remove_focus_spec.cr`).
#
# Without this, three dangling references survive the detach:
#   * `@_hover`  — `screen.hovered` keeps reporting an off-screen widget.
#   * `@_arm`    — a pending (armed) press later `start_drag`s a detached source.
#   * `@_drag`   — an in-flight drag whose source is removed stays modal forever
#                  (every later pointer event is swallowed by `#dispatch_mouse`).

private def ris_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

private def ris_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def ris_press(s, x, y)
  s.dispatch_mouse ris_mouse(::Tput::Mouse::Action::Down, x, y)
end

private def ris_move(s, x, y)
  s.dispatch_mouse ris_mouse(::Tput::Mouse::Action::Move, x, y, ::Tput::Mouse::Button::None)
end

describe "Screen#remove (mouse-interaction state)" do
  it "clears the hover pointer when the hovered widget is removed" do
    s = ris_screen
    box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4
    box.on(Crysterm::Event::MouseOver) { } # makes it mouse-responsive / hoverable

    ris_move s, 12, 6
    s.hovered.should eq box

    s.remove box
    s.hovered.should be_nil
  end

  it "discards a pending (armed) press so a later move can't drag a detached widget" do
    s = ris_screen
    box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4, draggable: true

    ris_press s, 12, 6 # arms the drag, but does not start it yet
    s.remove box

    # The press was armed on a widget that no longer belongs to the screen; the
    # next motion must NOT promote it into a drag.
    ris_move s, 14, 8
    s.dragging.should be_nil
  end

  it "tears down an in-flight drag when its source is removed" do
    s = ris_screen
    box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4, draggable: true
    ended = false
    box.on(Crysterm::Event::DragEnd) { ended = true }

    ris_press s, 12, 6
    ris_move s, 14, 8 # promotes arm -> in-flight drag
    s.dragging.should_not be_nil

    s.remove box
    s.dragging.should be_nil # drag no longer modal
    ended.should be_true     # DragEnd cleanup still ran
  end
end
