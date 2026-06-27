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
end
