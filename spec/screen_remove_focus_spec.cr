require "./spec_helper"

include Crysterm

# Removing a top-level widget from its `Window` must move keyboard focus out of
# the removed subtree, even when a descendant (not the removed widget itself)
# holds focus — otherwise a detached, off-screen widget keeps receiving key
# events. The focus check must happen before the unlink, so a focused
# descendant is still recognisable as belonging to the removed subtree
# (exercises `Window#remove`, separate from `Widget#remove`).

private def remove_focus_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Window#remove" do
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

    # Removing the top-level panel must not leave focus on the detached child.
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
