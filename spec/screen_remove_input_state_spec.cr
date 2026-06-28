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

private def ris_release(s, x, y)
  s.dispatch_mouse ris_mouse(::Tput::Mouse::Action::Up, x, y, ::Tput::Mouse::Button::None)
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

  it "clears the drop target (and never Drops on it) when the target is removed mid-drag" do
    s = ris_screen
    source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
    source.enable_drag reposition: false
    source.on(Crysterm::Event::DragStart) { |e| e.data["text/plain"] = "x" }

    target = Widget::Box.new parent: s, left: 40, top: 0, width: 10, height: 4
    target.on(Crysterm::Event::DragOver, &.accept)
    left = 0
    dropped_on_target = false
    target.on(Crysterm::Event::DragLeave) { left += 1 }
    target.on(Crysterm::Event::Drop) { dropped_on_target = true }

    ris_press s, 1, 1
    ris_move s, 2, 1  # promote arm -> in-flight transfer drag
    ris_move s, 44, 1 # drag over the target -> it becomes the (accepting) drop target
    s.dragging.try(&.target).should eq target

    s.remove target
    # The target was the drop target; removing it must clear the pointer (with a
    # DragLeave) rather than leave the drag aimed at a detached widget.
    s.dragging.should_not be_nil           # the drag itself (source still here) lives on
    s.dragging.try(&.target).should be_nil # but no longer points at the removed widget
    left.should eq(1)

    # A release at the old target position must NOT Drop on the now-detached widget.
    ris_release s, 44, 1
    dropped_on_target.should be_false
    s.dragging.should be_nil
  end

  it "releases an input grab when the grabbing widget is removed" do
    s = ris_screen
    # A modal pop-up that has grabbed input, plus another widget elsewhere.
    popup = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
    other = Widget::Box.new parent: s, left: 40, top: 0, width: 8, height: 4
    other.on(Crysterm::Event::MouseOver) { } # makes `other` hoverable

    s.grab popup
    s.grabbing?.should be_true
    # While grabbed, the pointer over `other` (outside the grab region) interacts
    # with nothing.
    ris_move s, 44, 1
    s.hovered.should be_nil

    # Removing the grabbing widget directly (bypassing its own ungrab-on-close)
    # must lift the modal lock rather than leave `@grabs` aimed at a detached
    # widget and block all interaction forever.
    s.remove popup
    s.grabbing?.should be_false

    ris_move s, 44, 1
    s.hovered.should eq other
  end
end
