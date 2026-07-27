require "./spec_helper"

include Crysterm

# Destroying a top-level widget (added straight onto a Window, so it has no
# widget parent — only a stored `@screen`) must detach it from the screen.
# `Widget#destroy` used to only call `remove_from_parent`, a no-op for a
# parent-less widget, leaving the destroyed widget in `screen.children` —
# still painted, keyable, possibly focused.

describe "Widget#destroy (top-level)" do
  it "removes a destroyed top-level widget from the screen's children" do
    s = headless_screen(20, 5, default_quit_keys: true)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    s.children.includes?(b).should be_true
    b.destroy
    s.children.includes?(b).should be_false
  end

  it "does not leave keyboard focus stranded on a destroyed top-level widget" do
    s = headless_screen(20, 5, default_quit_keys: true)
    b = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5, input: true
    s.focus b
    s.focused.should eq b
    b.destroy
    s.focused.should_not eq b
  end

  it "still unlinks a nested widget on destroy" do
    s = headless_screen(20, 5, default_quit_keys: true)
    parent = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5
    child = Widget::Box.new parent: parent, top: 0, left: 0, width: 10, height: 2
    parent.children.includes?(child).should be_true
    child.destroy
    parent.children.includes?(child).should be_false
  end
end
