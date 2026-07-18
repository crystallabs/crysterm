require "./spec_helper"

include Crysterm

# Regression specs for the BUGS9 "Input, Mouse, Focus, Drag, Events" fixes.
#
# 1. `window_drag.cr#drag_release`: when a drag is released over a target that
#    received `Event::DragEnter` but did NOT accept the drop, the target was
#    never told the drag left it (no `Drop`, no `DragLeave`), so it stayed in
#    its drag-entered visual state forever. Every `DragEnter` must be balanced
#    by exactly one `Drop` or `DragLeave`, as `retarget` (target change) and
#    `drag_cancel` (Escape) already guarantee. This closes the
#    rejection-on-release gap, for both the mouse and keyboard sensors.

private def bugs9_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w, height: h,
    default_quit_keys: false)
end

private def b9_mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def b9_press(s, x, y)
  s.dispatch_mouse b9_mouse(::Tput::Mouse::Action::Down, x, y)
end

private def b9_move(s, x, y)
  s.dispatch_mouse b9_mouse(::Tput::Mouse::Action::Move, x, y, ::Tput::Mouse::Button::None)
end

private def b9_release(s, x, y)
  s.dispatch_mouse b9_mouse(::Tput::Mouse::Action::Up, x, y, ::Tput::Mouse::Button::None)
end

private def b9_keypress(char : Char, key : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, key
end

describe "BUGS9 drag_release balances DragEnter on a non-accepting target" do
  it "emits DragLeave when a mouse drag is released over a target that refuses" do
    s = bugs9_screen
    source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
    source.drag_mode = :transfer; source.draggable = true

    target = Widget::Box.new parent: s, left: 40, top: 0, width: 10, height: 4
    entered = 0
    left = 0
    dropped = 0
    target.on(Crysterm::Event::DragEnter) { entered += 1 }
    target.on(Crysterm::Event::DragLeave) { left += 1 }
    target.on(Crysterm::Event::Drop) { dropped += 1 } # target never accepts

    b9_press s, 1, 1    # press over the source
    b9_move s, 2, 1     # promote the arm into a real drag
    b9_move s, 44, 1    # enter the target -> DragEnter
    b9_release s, 44, 1 # release OVER the target, which did not accept

    entered.should eq 1
    dropped.should eq 0
    # Before the fix this was 0: the target stayed stuck in its entered state.
    left.should eq 1
  end

  it "does NOT emit a spurious DragLeave when the target accepts (only Drop)" do
    s = bugs9_screen
    source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
    source.drag_mode = :transfer; source.draggable = true
    source.on(Crysterm::Event::DragStart) { |e| e.data["text/plain"] = "x" }

    target = Widget::Box.new parent: s, left: 40, top: 0, width: 10, height: 4
    target.on(Crysterm::Event::DragOver, &.accept)
    left = 0
    dropped = 0
    target.on(Crysterm::Event::DragLeave) { left += 1 }
    target.on(Crysterm::Event::Drop) { dropped += 1 }

    b9_press s, 1, 1
    b9_move s, 2, 1
    b9_move s, 44, 1
    b9_release s, 44, 1

    dropped.should eq 1
    left.should eq 0 # an accepted drop must NOT also fire DragLeave
  end

  it "emits DragLeave when a keyboard drag is dropped on a target that refuses" do
    s = bugs9_screen
    source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3,
      draggable: true, keys: true
    source.drag_mode = :transfer; source.draggable = true
    target = Widget::Box.new parent: s, left: 40, top: 0, width: 10, height: 4,
      keys: true
    entered = 0
    left = 0
    dropped = 0
    target.on(Crysterm::Event::DragEnter) { entered += 1 }
    target.on(Crysterm::Event::DragLeave) { left += 1 }
    target.on(Crysterm::Event::Drop) { dropped += 1 }

    source.focus
    s._drag_key_handled b9_keypress(' ') # pick up (keyboard drag)
    s.drag_session.should_not be_nil
    s._drag_key_handled b9_keypress('\0', ::Tput::Key::Tab) # focus -> target, DragEnter
    entered.should eq 1
    s._drag_key_handled b9_keypress(' ') # drop; target refuses
    s.drag_session.should be_nil

    dropped.should eq 0
    left.should eq 1
  end
end
