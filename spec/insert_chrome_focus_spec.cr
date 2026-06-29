require "./spec_helper"

include Crysterm

# Regression: `Window#insert` auto-focuses the first focusable widget when a
# screen has no current focus. That auto-focus must fire ONLY when the inserted
# subtree actually contributes a focusable widget. Inserting non-interactive
# chrome (a decorative box, a `Line`, the transient drag ghost) into a screen
# with no current focus must NOT yank focus onto an unrelated, pre-existing
# keyable widget that merely happens to be unfocused — the old unconditional
# `focus_next` did exactly that.
#
# Driven headlessly over in-memory IOs; no real terminal is touched.
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

    # Clear back to a no-focus state. `a` stays keyable and registered, just
    # unfocused (the state reachable after `rewind_focus`/history clearing).
    s.@history.clear
    s.focused.should be_nil

    # Insert non-interactive chrome. Before the fix this ran `focus_next`, which
    # re-focused `a`; now it is focus-neutral because the inserted box brings no
    # focusable widget.
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
    # The auto-focus gate runs DURING `Window#insert`, before `Widget#initialize`
    # finishes (and before its own construction-time `register_keyable`). A
    # `keys: true` widget therefore has to be registered by `insert` itself, or it
    # is absent from `@keyable` when the gate's `focus_next` runs and can never be
    # selected. Clear focus and confirm `focus_next` still reaches it — i.e. it is
    # actually in the keyable set, not merely auto-focused by luck of ordering.
    s = chrome_screen
    a = Widget::Box.new parent: s, keys: true
    s.@history.clear
    s.focused.should be_nil

    s.focus_next
    s.focused.should eq a
  end

  it "auto-focuses an input: true widget on insert too" do
    # `input: true` and `keys: true` both make a widget want keyboard focus
    # (`@keys || @input`); the insert gate must treat them identically.
    s = chrome_screen
    a = Widget::Box.new parent: s, input: true
    s.focused.should eq a
  end
end
