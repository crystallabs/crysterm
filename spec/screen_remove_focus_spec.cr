require "./spec_helper"

include Crysterm

# Removing a top-level widget from its `Screen` must move keyboard focus out of
# the removed subtree, even when it is a *descendant* (not the removed top-level
# widget itself) that currently holds focus. Otherwise a detached, off-screen
# widget keeps focus and keeps receiving key events. The focus condition must be
# sampled *before* the unlink, so a focused descendant is still recognisable as
# belonging to the removed subtree (this exercises `Screen#remove`, the separate
# path from `Widget#remove`).

private def remove_focus_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Screen#remove" do
  it "rewinds focus when the removed top-level widget itself is focused" do
    s = remove_focus_screen
    other = Widget::Box.new parent: s, keys: true
    panel = Widget::Box.new parent: s, keys: true

    other.focus
    panel.focus
    s.focused.should eq panel

    s.remove panel
    s.focused.should eq other
  end

  it "rewinds focus when a focused descendant is removed with its container" do
    s = remove_focus_screen
    other = Widget::Box.new parent: s, keys: true
    panel = Widget::Box.new parent: s, keys: true
    container = Widget::Box.new parent: panel, keys: true
    child = Widget::Box.new parent: container, keys: true

    other.focus
    child.focus
    s.focused.should eq child

    # Removing the top-level panel must not leave focus on the now-detached child.
    s.remove panel
    s.focused.should_not eq child
    s.focused.should eq other
  end

  it "leaves focus alone when an unrelated top-level widget is removed" do
    s = remove_focus_screen
    other = Widget::Box.new parent: s, keys: true
    panel = Widget::Box.new parent: s, keys: true
    Widget::Box.new parent: panel, keys: true

    other.focus
    s.remove panel
    s.focused.should eq other
  end
end
