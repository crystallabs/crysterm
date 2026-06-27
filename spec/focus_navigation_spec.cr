require "./spec_helper"

include Crysterm

# Keyboard focus navigation (`Screen#focus_offset` and friends). Driven
# headlessly over in-memory IOs; no real terminal is touched.

private def focus_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Screen#focus_offset" do
  it "moves focus between attached keyable widgets" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    s.focused.should eq a
    s.focus_next
    s.focused.should eq b
    s.focus_previous
    s.focused.should eq a
  end

  # Regression: `@keyable` is not pruned when a widget is removed, so it can hold
  # detached widgets (whose `@screen` is nil). `focus_offset` must treat those as
  # "not attached" via `screen?` rather than crashing on the raising `screen`.
  it "does not crash when a removed widget lingers in the keyable list" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    stale = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    s.remove stale # stale stays registered in @keyable but is now detached

    s.focus_next # would raise NilAssertionError before the fix
    s.focused.should_not be_nil
    s.focused.should_not eq stale
  end

  # Regression: focus-candidate selection must be ancestor-aware. A keyable
  # widget whose own `style.visible?` is still true but whose container is
  # hidden is not actually on screen, so navigation must skip over it instead of
  # landing focus inside an invisible subtree.
  it "skips a keyable widget whose ancestor is hidden" do
    s = focus_screen
    a = Widget::Box.new parent: s, keys: true
    container = Widget::Box.new parent: s
    inner = Widget::Box.new parent: container, keys: true
    b = Widget::Box.new parent: s, keys: true

    container.hide # inner stays flagged visible, but its parent is hidden

    a.focus
    s.focused.should eq a
    s.focus_next # must skip `inner` (hidden ancestor) and land on `b`
    s.focused.should eq b
    s.focused.should_not eq inner
  end
end
