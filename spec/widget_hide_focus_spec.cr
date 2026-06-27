require "./spec_helper"

include Crysterm

# Hiding a widget must move keyboard focus out of the hidden subtree, even when
# it is a *descendant* (not the widget itself) that currently holds focus.
# Otherwise an invisible widget keeps focus and keeps receiving key events.

private def hide_focus_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Widget#hide" do
  it "rewinds focus when the hidden widget itself is focused" do
    s = hide_focus_screen
    other = Widget::Box.new parent: s, keys: true
    panel = Widget::Box.new parent: s, keys: true

    other.focus
    panel.focus
    s.focused.should eq panel

    panel.hide
    s.focused.should eq other
  end

  it "rewinds focus when a focused descendant is hidden with its container" do
    s = hide_focus_screen
    other = Widget::Box.new parent: s, keys: true
    panel = Widget::Box.new parent: s, keys: true
    child = Widget::Box.new parent: panel, keys: true

    other.focus
    child.focus
    s.focused.should eq child

    panel.hide
    # Focus must not stay on the now-invisible child.
    s.focused.should_not eq child
    s.focused.should eq other
  end

  it "leaves focus alone when an unrelated widget is hidden" do
    s = hide_focus_screen
    a = Widget::Box.new parent: s, keys: true
    b = Widget::Box.new parent: s, keys: true

    a.focus
    b.hide
    s.focused.should eq a
  end
end
