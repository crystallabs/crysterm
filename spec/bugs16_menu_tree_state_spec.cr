require "./spec_helper"

include Crysterm

# B16-32: Menu#on_keypress's Right-key branch opened the highlighted action's
# submenu with only `act.menu?` -- no `act.enabled?` gate, unlike every other
# submenu-opening path (#hover_item, #activate_index). A disabled submenu row
# could still be entered (and its children fired) with the keyboard, though
# Enter/click on the same row correctly did nothing.
#
# B16-33: Tree::Node#add / Tree#add re-parented a node without detaching it
# from its old parent (or old tree's roots) first, so a moved node stayed in
# two places at once and #rebuild's flatten (src/widget/tree.cr) rendered it
# on two rows.

private def add_mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

describe Crysterm::Widget::Menu do
  it "does not open a disabled action's submenu on Right" do
    s = add_mem_screen
    m = Widget::Menu.new parent: s, top: 0, left: 0, width: 20, height: 8

    pdf = Action.new "PDF"
    csv = Action.new "CSV"
    export = m.add_submenu "Export", [pdf, csv]
    export.enabled = false
    m << Action.new("Other")

    s._render
    m.current_index = 0 # highlight the disabled "Export" row

    m.on_keypress Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Right)
    s._render

    # No submenu opened, and focus stayed on the parent menu.
    s.focused.should eq m
  end

  it "still opens an enabled action's submenu on Right" do
    s = add_mem_screen
    m = Widget::Menu.new parent: s, top: 0, left: 0, width: 20, height: 8

    export = m.add_submenu "Export", [Action.new("PDF"), Action.new("CSV")]
    export.enabled = true

    s._render
    m.current_index = 0

    m.on_keypress Crysterm::Event::KeyPress.new('\0', ::Tput::Key::Right)
    s._render

    child = s.focused
    child.should_not eq m
    child.is_a?(Widget::Menu).should be_true
  end
end

describe Crysterm::Widget::Tree do
  it "detaches a node from its old parent before re-parenting under a new node" do
    s = add_mem_screen
    tree = Widget::Tree.new parent: s, width: 30, height: 12

    src = tree.add "src"
    widget = src.add "widget"
    other = tree.add "other"

    src.children.should contain widget

    # Move `widget` under `other`: must vanish from `src`'s children, not just
    # gain `other` as an additional parent.
    other.add widget

    src.children.should_not contain widget
    other.children.should contain widget
    widget.parent.should eq other

    # The flattened view has exactly one row per node -- no duplicate. Both
    # parents must be expanded first, or `widget`'s row is merely hidden
    # (collapsed), masking a real duplicate as an absence rather than proving
    # there isn't one.
    tree.expand_all
    tree.nodes.count(widget).should eq 1
    tree.nodes.count(&.text.==("widget")).should eq 1
  end

  it "detaches a root node from Tree#roots before re-adding it as a child" do
    s = add_mem_screen
    tree = Widget::Tree.new parent: s, width: 30, height: 12

    top = tree.add "top"
    holder = tree.add "holder"

    tree.roots.should contain top

    holder.add top

    tree.roots.should_not contain top
    holder.children.should contain top
    top.parent.should eq holder

    # `holder` must be expanded for `top`'s row to be visible at all -- see
    # the comment in the previous example.
    tree.expand_all
    tree.nodes.count(top).should eq 1
  end

  it "no-ops re-adding a node that is already a child of the receiver" do
    s = add_mem_screen
    tree = Widget::Tree.new parent: s, width: 30, height: 12

    src = tree.add "src"
    widget = src.add "widget"

    src.add widget # already a child of `src`: must not duplicate

    src.children.count(widget).should eq 1
    tree.expand_all
    tree.nodes.count(widget).should eq 1
  end

  it "no-ops re-adding an existing root to the tree" do
    s = add_mem_screen
    tree = Widget::Tree.new parent: s, width: 30, height: 12

    top = tree.add "top"
    tree.add top # already a root: must not duplicate

    tree.roots.count(top).should eq 1
    tree.nodes.count(top).should eq 1
  end
end
