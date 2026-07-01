require "./spec_helper"

include Crysterm

# Regression: `Window#insert` auto-focuses the first focusable widget when a
# screen has no current focus, but only when the inserted subtree actually
# contributes one. Inserting non-interactive chrome (decorative box, `Line`,
# transient drag ghost) must NOT yank focus onto an unrelated pre-existing
# keyable widget that merely happens to be unfocused — the old unconditional
# `focus_next` did exactly that.
#
# Headless, no real terminal.
private def chrome_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Window#insert auto-focus" do
  it "does not re-focus an unrelated keyable widget when inserting non-focusable chrome" do
    s = chrome_screen
    Widget::Box.new parent: s, keys: true # auto-focused as the first focusable

    # Clear to a no-focus state; `a` stays keyable and registered, just
    # unfocused (reachable after `rewind_focus`/history clearing).
    s.@history.clear
    s.focused.should be_nil

    # Insert non-interactive chrome. Before the fix this ran `focus_next` and
    # re-focused `a`; now focus-neutral since the box brings no focusable widget.
    Widget::Box.new parent: s
    s.focused.should be_nil
  end

  it "still auto-focuses the inserted widget when it is itself focusable" do
    s = chrome_screen
    a = Widget::Box.new parent: s, keys: true
    s.focused.should eq a # first focusable widget gets focus on insert
  end

  it "does not disturb existing focus when inserting chrome" do
    s = chrome_screen
    a = Widget::Box.new parent: s, keys: true
    s.focused.should eq a

    Widget::Box.new parent: s # non-focusable chrome
    s.focused.should eq a     # focus stays put (this path already held)
  end

  it "registers a keys: true widget into the keyable set at insert time" do
    # The auto-focus gate runs during `Window#insert`, before `Widget#initialize`
    # finishes its own construction-time `register_keyable`. So `insert` itself
    # must register a `keys: true` widget, or it's absent from `@keyable` when
    # the gate's `focus_next` runs. Clear focus and confirm `focus_next` still
    # reaches it, confirming it's in the keyable set and not auto-focused by luck.
    s = chrome_screen
    a = Widget::Box.new parent: s, keys: true
    s.@history.clear
    s.focused.should be_nil

    s.focus_next
    s.focused.should eq a
  end

  it "auto-focuses an input: true widget on insert too" do
    # `input: true` and `keys: true` both mean `@keys || @input`; the insert
    # gate must treat them identically.
    s = chrome_screen
    a = Widget::Box.new parent: s, input: true
    s.focused.should eq a
  end
end
