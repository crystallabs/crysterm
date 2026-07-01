require "./spec_helper"

include Crysterm

# Counterpart to `widget_reparent_screen_child_spec.cr` (pulling a top-level
# widget into a widget); this covers moving a widget onto a screen. `Window#insert`
# previously never detached the element from its old home, leaving it
# double-parented: listed in both the old container's and new screen's `children`,
# rendered twice.

private def headless_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 10)
end

describe "Window#insert reparenting an existing widget onto the screen" do
  it "removes a top-level widget from its previous screen (no double-parenting across screens)" do
    s1 = headless_screen
    s2 = headless_screen

    w = Widget::Box.new parent: s1, width: 4, height: 2
    s1.children.includes?(w).should be_true

    s2.insert w

    # Moved onto s2 as a top-level child...
    s2.children.includes?(w).should be_true
    w.window?.should eq s2
    # ...and no longer left behind in s1's children.
    s1.children.includes?(w).should be_false
  end

  it "removes a nested widget from its widget parent when inserted onto the screen" do
    s = headless_screen
    container = Widget::Box.new parent: s, width: 10, height: 5
    child = Widget::Box.new parent: container, width: 4, height: 2
    container.children.includes?(child).should be_true

    s.insert child

    # Now a top-level child of the screen...
    s.children.includes?(child).should be_true
    child.parent.should be_nil
    child.window?.should eq s
    # ...and detached from its old widget parent.
    container.children.includes?(child).should be_false
  end
end
