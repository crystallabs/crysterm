require "./spec_helper"

include Crysterm

# Regression specs for the BUGS6 "Core Infrastructure & Events" fixes:
#
#  1. `ToolBar#uninstall_action_shortcuts` / `MenuBar#uninstall_menu_shortcuts`
#     guarded on `window?`, which is already nil inside the `Event::Detached`
#     handler (`Widget#remove` nulls `parent`/`window` before `Window#detach`
#     emits `Detached`). So detaching a bar never withdrew its window-level
#     accelerators — stale handlers kept firing and the `Window` leaked as a hash
#     key. Fixed to take the previous window from the event payload.
#
#  2. `Widget#hide`/`#show` emitted only on self, so descendants never ran their
#     own Hide/Show cleanup (tooltip removal, OSC-22 pointer-shape restore) when
#     an ancestor was hidden. Fixed by `emit_descendants` after the self-emit.
#
#  3. `Action#shortcut_hosts` ignored its `window` argument, testing focus across
#     hosts on *other* windows too — a multi-window shortcut could fire on the
#     wrong window. Fixed to filter associated widgets to the given window.
#
#  4. `Action#feed_shortcut` left a half-entered chord prefix stale on an early
#     return (out-of-context press, disabled action, dropped auto-repeat), so the
#     chord could complete spuriously later. Fixed to clear the pending prefix.

private def bugs6_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

describe "BUGS6 #1 ToolBar/MenuBar uninstall shortcuts on detach" do
  it "stops firing a ToolBar action's shortcut after the bar is detached" do
    s = bugs6_screen
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    a = Action.new "Run", shortcut: Tput::Key::CtrlR
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlR)
    fired.should eq 1

    # Detaching the bar must withdraw its accelerator via the `Detached` handler.
    s.remove tb
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlR)
    fired.should eq 1 # no further dispatch
  end

  it "stops firing a MenuBar menu action's shortcut after the bar is detached" do
    s = bugs6_screen
    bar = Crysterm::Widget::MenuBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    copy = Action.new "Copy", shortcut: Tput::Key::CtrlC
    fired = 0
    copy.on(Event::Triggered) { fired += 1 }
    bar.add_menu "Edit", [copy]

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlC)
    fired.should eq 1

    s.remove bar
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlC)
    fired.should eq 1 # accelerator gone
  end
end

describe "BUGS6 #2 hide/show propagate to descendants" do
  it "emits Event::Hide and Event::Show on descendants" do
    s = bugs6_screen
    parent = Crysterm::Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10
    child = Crysterm::Widget::Box.new parent: parent, top: 0, left: 0, width: 5, height: 1

    hides = 0
    shows = 0
    child.on(Crysterm::Event::Hide) { hides += 1 }
    child.on(Crysterm::Event::Show) { shows += 1 }

    parent.hide
    hides.should eq 1
    parent.show
    shows.should eq 1
  end

  it "restores the GUI pointer shape of a hovered child when its ancestor is hidden" do
    buf = IO::Memory.new
    s = Crysterm::Window.new(input: IO::Memory.new, output: buf, error: IO::Memory.new)
    s.mouse_cursor_shaping = true
    parent = Crysterm::Widget::Box.new parent: s, left: 0, top: 0, width: 10, height: 3
    child = Crysterm::Widget::Box.new parent: parent, left: 0, top: 0, width: 10, height: 3,
      mouse_cursor_shape: ::Tput::MouseCursorShape::PointingHandCursor
    s.tput.flush; buf.clear # discard construction output

    # Hover the child -> pushes the hand pointer.
    s.dispatch_mouse ::Tput::Mouse::Event.new(
      ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, 2, 1, source: :test)
    s.tput.flush
    buf.to_s.should contain "\e]22;hand2\a"
    buf.clear
    s.hovered.should eq child

    # Hiding the *parent* must run the child's Hide cleanup and restore default.
    parent.hide
    s.tput.flush
    buf.to_s.should contain "\e]22;\a"
  end
end

describe "BUGS6 #3 shortcut_hosts filters by window (multi-window)" do
  it "does not fire a Widget-context shortcut because a host on another window is focused" do
    s_a = bugs6_screen
    s_b = bugs6_screen
    tb_a = Crysterm::Widget::ToolBar.new parent: s_a, top: 0, left: 0, width: "100%", height: 1
    tb_b = Crysterm::Widget::ToolBar.new parent: s_b, top: 0, left: 0, width: "100%", height: 1
    # A separate focusable widget on B so we can hold B's focus *off* tb_b while a
    # host on A is focused — that is the exact "host on another window" condition.
    other_b = Crysterm::Widget::Box.new parent: s_b, top: 1, left: 0, width: 5, height: 1, keys: true

    a = Action.new "Bold", shortcut: Tput::Key::CtrlB,
      shortcut_context: Action::ShortcutContext::Widget
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb_a.add_action a
    tb_b.add_action a

    tb_a.focus
    other_b.focus # divert window B's focus away from tb_b
    tb_a.focused?.should be_true
    tb_b.focused?.should be_false

    # Pressed on window B while only a host on window A is focused: must NOT fire.
    s_b.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 0

    # Pressed on window A where the host is focused: fires.
    s_a.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1

    # Focusing the host on B lets it fire there too.
    tb_b.focus
    s_b.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 2
  end
end

describe "BUGS6 #4 feed_shortcut clears stale chord prefix on early return" do
  it "clears the pending prefix when the action is disabled mid-chord" do
    s = bugs6_screen
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    a = Action.new "Bold", shortcuts: [[Tput::Key::CtrlK, Tput::Key::CtrlB]]
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a

    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlK) # pending = [CtrlK]
    a.enabled = false
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB) # disabled -> clears pending
    a.enabled = true
    # With the prefix cleared, a lone CtrlB is not a shortcut and must not fire.
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 0

    # The full chord still works afterwards.
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlK)
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1
  end

  it "clears the pending prefix when focus leaves the host mid-chord (Widget context)" do
    s = bugs6_screen
    tb = Crysterm::Widget::ToolBar.new parent: s, top: 0, left: 0, width: "100%", height: 1
    other = Crysterm::Widget::Box.new parent: s, top: 2, left: 0, width: 5, height: 1, keys: true
    a = Action.new "Bold", shortcuts: [[Tput::Key::CtrlK, Tput::Key::CtrlB]],
      shortcut_context: Action::ShortcutContext::Widget
    fired = 0
    a.on(Event::Triggered) { fired += 1 }
    tb.add_action a

    tb.focus
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlK) # pending = [CtrlK]

    other.focus                                                  # focus leaves the host -> shortcut inactive
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB) # inactive -> clears pending

    tb.focus # focus returns
    # Prefix cleared: the intervening focus change must not let the chord complete.
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 0

    # And the full chord fires cleanly.
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlK)
    s.emit Crysterm::Event::KeyPress.new('\0', Tput::Key::CtrlB)
    fired.should eq 1
  end
end
