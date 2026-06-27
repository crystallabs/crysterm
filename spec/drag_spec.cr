require "./spec_helper"

include Crysterm

# Drag-and-drop engine (`src/drag.cr`, `src/screen_drag.cr`, and the mouse/
# keyboard sensors). Driven headlessly over in-memory IOs so no real terminal is
# touched. The mouse sensor is exercised through the public `#dispatch_mouse`
# entry point (the same one the terminal/gpm inputs feed), and the keyboard
# sensor through `#_drag_key_handled`.

private def drag_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

private def mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def press(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Down, x, y)
end

private def move(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Move, x, y, ::Tput::Mouse::Button::None)
end

private def release(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Up, x, y, ::Tput::Mouse::Button::None)
end

private def keypress(char : Char, key : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, key
end

# A transfer source over an always-accepting target, for action-negotiation tests.
private def transfer_setup
  s = drag_screen
  source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
  source.enable_drag reposition: false
  source.on(Crysterm::Event::DragStart) { |e| e.data["text/plain"] = "x" }
  target = Widget::Box.new parent: s, left: 40, top: 0, width: 10, height: 4
  target.on(Crysterm::Event::DragOver, &.accept)
  {s, target}
end

describe "drag-and-drop" do
  describe "reposition (self-move) via mouse" do
    it "moves the widget with the pointer, keeping the grab offset" do
      s = drag_screen
      box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4, draggable: true

      press s, 12, 6 # grab at offset (2, 1) within the box
      move s, 14, 8  # promotes arm -> drag, then this is the first motion

      # widget follows: left = anchorX - dx, top = anchorY - dy
      box.left.should eq(12)
      box.top.should eq(7)

      move s, 20, 12
      box.left.should eq(18)
      box.top.should eq(11)

      release s, 20, 12
      s.dragging.should be_nil
    end

    it "treats a press+release without motion as a click, not a drag" do
      s = drag_screen
      box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4, draggable: true
      clicked = false
      box.on(Event::Click) { clicked = true }

      press s, 12, 6
      release s, 12, 6

      clicked.should be_true
      box.left.should eq(10) # unmoved
      s.dragging.should be_nil
    end

    it "moves a nested draggable widget relative to its parent's content origin" do
      s = drag_screen
      # A bordered container offsets its children's content origin by (1, 1).
      panel = Widget::Box.new parent: s, left: 20, top: 6, width: 30, height: 12,
        style: Style.new(border: true)
      # Child `left`/`top` are relative to the panel's content corner
      # (panel.aleft + panel.ileft == 21, panel.atop + panel.itop == 7).
      box = Widget::Box.new parent: panel, left: 4, top: 3, width: 8, height: 4, draggable: true

      box.aleft.should eq(25) # 21 + 4
      box.atop.should eq(10)  # 7 + 3

      press s, 27, 11 # grab at absolute (27, 11) -> offset (2, 1) within the box
      move s, 30, 14  # promote arm -> drag, first motion to absolute (30, 14)

      # Grab offset preserved: the widget's absolute corner follows the pointer.
      box.aleft.should eq(28) # 30 - 2
      box.atop.should eq(13)  # 14 - 1
      # ...which is a parent-relative left/top of (7, 6), NOT the absolute (28, 13).
      box.left.should eq(7)
      box.top.should eq(6)
    end

    it "clamps the widget within the screen bounds" do
      s = drag_screen # 80x24
      box = Widget::Box.new parent: s, left: 2, top: 2, width: 8, height: 4, draggable: true

      press s, 2, 2
      move s, 1, 1     # promote
      move s, -50, -50 # far past the top-left corner
      box.left.should eq(0)
      box.top.should eq(0)
    end
  end

  describe "data transfer via mouse" do
    it "negotiates a drop: source advertises payload, target accepts, Drop fires" do
      s = drag_screen
      source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
      source.enable_drag reposition: false
      source.on(Event::DragStart) { |e| e.data["text/plain"] = "parcel" }

      target = Widget::Box.new parent: s, left: 40, top: 0, width: 10, height: 4
      target.on(Event::DragOver) { |e| e.accept if e.data.has? "text/plain" }

      received = nil
      target.on(Event::Drop) { |e| received = e.data["text/plain"] }

      ended = false
      dropped = false
      source.on(Event::DragEnd) { |e| ended = true; dropped = e.dropped? }

      press s, 1, 1
      move s, 2, 1 # promote the drag (source stays put, reposition off)
      source.left.should eq(0)
      move s, 44, 1 # drag over the target
      release s, 44, 1

      received.should eq("parcel")
      ended.should be_true
      dropped.should be_true
      s.dragging.should be_nil
    end

    it "does not Drop on a target that refuses the payload" do
      s = drag_screen
      source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
      source.enable_drag reposition: false
      source.on(Event::DragStart) { |e| e.data["application/x-thing"] = "x" }

      target = Widget::Box.new parent: s, left: 40, top: 0, width: 10, height: 4
      target.on(Event::DragOver) { |e| e.accept if e.data.has? "text/plain" } # won't match

      dropped_on_target = false
      target.on(Event::Drop) { dropped_on_target = true }
      end_dropped = true
      source.on(Event::DragEnd) { |e| end_dropped = e.dropped? }

      press s, 1, 1
      move s, 2, 1
      move s, 44, 1
      release s, 44, 1

      dropped_on_target.should be_false
      end_dropped.should be_false
    end

    it "emits DragEnter/DragLeave as the pointer crosses a target" do
      s = drag_screen
      source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
      source.enable_drag reposition: false

      target = Widget::Box.new parent: s, left: 40, top: 0, width: 10, height: 4
      entered = 0
      left = 0
      target.on(Event::DragEnter) { entered += 1 }
      target.on(Event::DragLeave) { left += 1 }

      press s, 1, 1
      move s, 2, 1  # promote, not over target
      move s, 44, 1 # enter target
      move s, 45, 2 # still over target
      move s, 70, 1 # leave target
      release s, 70, 1

      entered.should eq(1)
      left.should eq(1)
    end
  end

  describe "keyboard sensor" do
    it "lifts a focused draggable widget with Space and nudges it with arrows" do
      s = drag_screen
      box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4, draggable: true, keys: true
      box.focus

      # A real Space press is printable: char == ' ', key == nil (the input
      # layer only sets `key` for control sequences). Must still lift.
      s._drag_key_handled(keypress(' ')).should be_true
      s.dragging.should_not be_nil

      s._drag_key_handled(keypress('\0', ::Tput::Key::Right)).should be_true
      s._drag_key_handled(keypress('\0', ::Tput::Key::Down)).should be_true
      box.left.should eq(11)
      box.top.should eq(6)

      # Drop with Space (char-only, as it really arrives).
      s._drag_key_handled(keypress(' ')).should be_true
      s.dragging.should be_nil
    end

    it "drops with Enter (a control key, delivered with a key)" do
      s = drag_screen
      box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4, draggable: true, keys: true
      box.focus
      s._drag_key_handled(keypress(' ')).should be_true
      s._drag_key_handled(keypress('\r', ::Tput::Key::Enter)).should be_true
      s.dragging.should be_nil
    end

    it "cancels a keyboard drag with Escape" do
      s = drag_screen
      box = Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4, draggable: true, keys: true
      box.focus

      ended = false
      dropped = true
      box.on(Event::DragEnd) { |e| ended = true; dropped = e.dropped? }

      s._drag_key_handled(keypress(' '))
      s._drag_key_handled(keypress('\0', ::Tput::Key::Escape)).should be_true

      s.dragging.should be_nil
      ended.should be_true
      dropped.should be_false
    end

    it "ignores Space when the focused widget is not draggable" do
      s = drag_screen
      box = Widget::Box.new parent: s, left: 0, top: 0, width: 4, height: 2, keys: true
      box.focus
      s._drag_key_handled(keypress(' ')).should be_false
      s.dragging.should be_nil
    end
  end

  describe "modifier-driven action (Ctrl=Copy, Shift=Move)" do
    it "negotiates Copy when Ctrl is held" do
      s, target = transfer_setup
      action = nil
      target.on(Event::Drop) { |e| action = e.data.action }

      s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, 1, 1, ctrl: true, source: :test)
      s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, 44, 1, ctrl: true, source: :test)
      s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Up, ::Tput::Mouse::Button::None, 44, 1, ctrl: true, source: :test)

      action.should eq(Crysterm::DragAction::Copy)
    end

    it "negotiates Move when Shift is held" do
      s, target = transfer_setup
      action = nil
      target.on(Event::Drop) { |e| action = e.data.action }

      s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, ::Tput::Mouse::Button::Left, 1, 1, shift: true, source: :test)
      s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, 44, 1, shift: true, source: :test)
      s.dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Up, ::Tput::Mouse::Button::None, 44, 1, shift: true, source: :test)

      action.should eq(Crysterm::DragAction::Move)
    end
  end

  describe "announce hook" do
    it "reports lift / over / drop to the announce sink" do
      s = drag_screen
      msgs = [] of String
      s.drag_announce = ->(m : String) { msgs << m; nil }

      source = Widget::Box.new parent: s, name: "src", left: 0, top: 0, width: 6, height: 3
      source.enable_drag reposition: false
      target = Widget::Box.new parent: s, name: "dst", left: 40, top: 0, width: 10, height: 4
      target.on(Event::DragOver, &.accept)

      press s, 1, 1
      move s, 2, 1
      move s, 44, 1
      release s, 44, 1

      msgs.first.should contain("Picked up src")
      msgs.any?(&.includes?("Over dst")).should be_true
      msgs.last.should contain("Dropped on dst")
    end
  end

  describe "ghost" do
    it "floats a ghost during a transfer drag, removed on drop, never a target" do
      s = drag_screen
      source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
      source.enable_drag reposition: false
      source.on(Event::DragStart) { |e| e.data["text/plain"] = "cargo" }

      press s, 1, 1
      move s, 10, 5
      # A ghost exists and sits under the pointer, but is not hit-testable.
      s.widget_at(11, 5).should be_nil
      release s, 10, 5
      # Cleaned up: nothing lingering under the old pointer position.
      s.widget_at(11, 5).should be_nil
    end

    it "does not float a ghost for a reposition drag" do
      s = drag_screen
      Widget::Box.new parent: s, left: 10, top: 5, width: 8, height: 4, draggable: true
      press s, 12, 6
      move s, 14, 8
      # No extra widget was added under the pointer (only the box itself moved).
      s.widget_at(30, 20).should be_nil
      release s, 14, 8
    end
  end

  describe "two-click mouse fallback" do
    it "lifts on the first click and drops on the second (no motion needed)" do
      s = drag_screen
      s.drag_two_click = true

      source = Widget::Box.new parent: s, left: 0, top: 0, width: 6, height: 3
      source.enable_drag reposition: false
      source.on(Event::DragStart) { |e| e.data["text/plain"] = "p" }
      target = Widget::Box.new parent: s, left: 40, top: 0, width: 10, height: 4
      target.on(Event::DragOver, &.accept)
      received = nil
      target.on(Event::Drop) { |e| received = e.data["text/plain"] }

      press s, 1, 1 # first click: lift
      s.dragging.should_not be_nil
      press s, 44, 1 # second click over target: drop
      received.should eq("p")
      s.dragging.should be_nil
    end
  end

  describe "desktop-edge bridges" do
    it "writes OSC 52 to the output when copying to clipboard" do
      outio = IO::Memory.new
      s = Crysterm::Screen.new input: IO::Memory.new, output: outio, error: IO::Memory.new
      s.copy_to_clipboard "hello"
      outio.to_s.should contain("\e]52;c;")
      outio.to_s.should contain(Base64.strict_encode("hello"))
    end

    it "synthesizes a text/uri-list drop for an external file-drop" do
      s = drag_screen
      zone = Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 4
      zone.on(Event::DragOver) { |e| e.accept if e.data.has? "text/uri-list" }
      got = nil
      zone.on(Event::Drop) { |e| got = e.data["text/uri-list"] }

      s.drop_external(["file:///tmp/a.png"], zone).should be_true
      got.should eq("file:///tmp/a.png")
    end
  end
end
