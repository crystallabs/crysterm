require "./spec_helper"

include Crysterm

# Reparenting a *top-level* widget (one listed directly in a screen's `children`)
# into another widget must remove it from the screen's `children` — otherwise it
# stays in BOTH the old screen's `children` and the new parent's, i.e. it is
# double-parented (rendered twice, inconsistent tree). `Widget#insert` previously
# only called `element.remove_from_parent`, which can't detach a top-level widget
# (it has no widget `@parent`, only a stored screen), so the move leaked.

private def headless_screen
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 10)
end

describe "Widget#insert reparenting a top-level widget" do
  it "removes it from the screen's children (no double-parenting)" do
    s = headless_screen
    container = Widget::Box.new parent: s, width: 10, height: 5
    child = Widget::Box.new parent: s, width: 4, height: 2

    before = s.children.size
    s.children.includes?(child).should be_true

    container.append child

    # Now nested under `container`...
    child.parent.should eq container
    container.children.includes?(child).should be_true
    # ...and no longer a top-level child of the screen.
    s.children.includes?(child).should be_false
    s.children.size.should eq before - 1
    # Screen is still derived correctly through the new parent.
    child.screen?.should eq s
  end
end
