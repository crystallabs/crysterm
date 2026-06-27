require "./spec_helper"

include Crysterm

# Destroying a *top-level* widget (one added straight onto a Screen, so it has
# no widget parent — only a stored `@screen`) must detach it from the screen.
# Before the fix, `Widget#destroy` only called `remove_from_parent`, which is a
# no-op for a parent-less widget, so the destroyed widget lingered in
# `screen.children` — still painted, still keyable, possibly still focused.

private def sized_screen(w, h)
  Crysterm::Screen.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h)
end

describe "Widget#destroy (top-level)" do
  it "removes a destroyed top-level widget from the screen's children" do
    s = sized_screen 20, 5
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    s.children.includes?(b).should be_true
    b.destroy
    s.children.includes?(b).should be_false
  end

  it "does not leave keyboard focus stranded on a destroyed top-level widget" do
    s = sized_screen 20, 5
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5, input: true
    s.focus b
    s.focused.should eq b
    b.destroy
    s.focused.should_not eq b
  end

  it "still unlinks a nested widget on destroy" do
    s = sized_screen 20, 5
    parent = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    child = Widget::Box.new parent: parent, top: 0, left: 0, width: 10, height: 2
    parent.children.includes?(child).should be_true
    child.destroy
    parent.children.includes?(child).should be_false
  end
end
