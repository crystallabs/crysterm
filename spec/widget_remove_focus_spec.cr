require "./spec_helper"

include Crysterm

# Removing a widget from its (widget) parent must move keyboard focus out of the
# removed subtree, even when it is a *descendant* (not the removed widget itself)
# that currently holds focus. Otherwise a detached, off-screen widget keeps focus
# and keeps receiving key events. The focus condition must be sampled *before*
# the unlink, so a focused descendant is still recognisable as belonging to the
# removed subtree (`Widget::Box.new(parent: panel, ...)` exercises `Widget#remove`,
# not the separate `Window#remove`).

private def remove_focus_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe "Widget#remove" do
  it "rewinds focus when the removed widget itself is focused" do
    s = remove_focus_screen
    other = Widget::Box.new parent: s, keys: true
    panel = Widget::Box.new parent: s, keys: true
    container = Widget::Box.new parent: panel, keys: true

    other.focus
    container.focus
    s.focused.should eq container

    panel.remove container
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

    # Removing the container must not leave focus on the now-detached child.
    panel.remove container
    s.focused.should_not eq child
    s.focused.should eq other
  end

  it "leaves focus alone when an unrelated widget is removed" do
    s = remove_focus_screen
    other = Widget::Box.new parent: s, keys: true
    panel = Widget::Box.new parent: s, keys: true
    container = Widget::Box.new parent: panel, keys: true

    other.focus
    panel.remove container
    s.focused.should eq other
  end
end
