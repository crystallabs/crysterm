require "./spec_helper"

include Crysterm

# `Widget#insert` (src/widget_children.cr) must refuse to make a widget a child
# of itself or of one of its own descendants. Such a move splices a cycle into
# the widget tree, after which every parent/descendant walk — `#screen?`,
# `#ancestor_of?`, `#invalidate_screen_cache`, the renderer's traversal —
# recurses forever and overflows the stack. The corruption happens
# synchronously inside `append` (the `parent=` setter walks the now-cyclic
# subtree to invalidate the screen cache), so without the guard these examples
# crash rather than fail.

private def headless_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 10)
end

describe "Widget#insert cycle guard" do
  it "refuses to make a widget a child of itself" do
    s = headless_screen
    a = Widget::Box.new parent: s, width: 4, height: 2

    a.append a # would create a self-cycle

    a.children.includes?(a).should be_false
    a.parent.should_not eq a
    a.ancestor_of?(a).should be_false # tree walks still terminate
    a.window?.should eq s
  end

  it "refuses to make a widget a child of its own descendant" do
    s = headless_screen
    a = Widget::Box.new parent: s, width: 10, height: 5
    b = Widget::Box.new width: 4, height: 2
    a.append b

    b.append a # `a` is an ancestor of `b` -> would create a cycle

    # Tree unchanged: `a` stays top-level, `b` stays nested under `a`.
    b.children.includes?(a).should be_false
    a.children.includes?(b).should be_true
    b.parent.should eq a
    s.children.includes?(a).should be_true
    a.window?.should eq s
    b.window?.should eq s
  end

  it "still allows reordering an existing child (no false positive)" do
    s = headless_screen
    parent = Widget::Box.new parent: s, width: 10, height: 5
    c1 = Widget::Box.new width: 2, height: 1
    c2 = Widget::Box.new width: 2, height: 1
    parent.append c1
    parent.append c2

    parent.insert c1, -1 # re-home the existing child at the end

    parent.children.includes?(c1).should be_true
    c1.parent.should eq parent
  end
end
