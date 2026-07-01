require "./spec_helper"

include Crysterm

private def tree_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 40, height: 16)
end

describe Crysterm::Widget::Tree do
  it "adopts a detached subtree on attach (later edits refresh the view)" do
    s = tree_screen
    tree = Widget::Tree.new parent: s, width: 30, height: 12

    # Multi-level subtree built before attaching: owning tree unknown, so
    # nodes have a nil `#tree`.
    root = Widget::Tree::Node.new "root"
    child = root.add "child"
    grandchild = child.add "grandchild"
    child.tree.should be_nil
    grandchild.tree.should be_nil

    # Attaching the root must adopt the entire subtree, not just the root —
    # otherwise an edit through a descendant finds `@tree` nil and skips the
    # `rebuild` that keeps the flattened view in sync.
    tree.add root
    root.tree.should eq tree
    child.tree.should eq tree
    grandchild.tree.should eq tree

    # A node added through the (formerly detached) child is now owned too.
    leaf = child.add "leaf"
    leaf.tree.should eq tree
  end
end
