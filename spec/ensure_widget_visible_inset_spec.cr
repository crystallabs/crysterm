require "./spec_helper"

include Crysterm

# `ensure_widget_visible` must map the descendant's outer-relative top
# (`child.rtop`, which folds in the scroll area's near inset `itop`) down to a
# content-row index before calling `ensure_visible`. Passing `child.rtop`
# verbatim is correct only when `itop == 0`; with a border (`itop == 1`) it
# scrolls one row too far, failing to reveal a child above the viewport.
describe "Widget#ensure_widget_visible with a bordered scroll area" do
  it "reveals a descendant above the viewport, accounting for the top inset" do
    s = headless_screen(80, 24)
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0,
      width: 20, height: 8, style: Crysterm::Style.new(border: true),
      content: (1..40).map { |i| "line#{i}" }.join("\n")
    child = Crysterm::Widget::Box.new parent: box, top: 10, left: 0,
      width: 5, height: 1, content: "x"
    s.repaint

    box.itop.should eq 1                # border contributes a top inset
    content_row = child.rtop - box.itop # the child's true content-row index
    content_row.should eq 10

    # Scroll the viewport well past the child so it sits above the top edge.
    box.child_base = 25

    box.ensure_widget_visible(child).should be_true

    # The child's top must be within the visible content rows, not stranded one
    # row above by the missing-inset over-scroll.
    (box.child_base <= content_row).should be_true
    visible = box.aheight - box.ivertical
    (content_row + child.aheight - 1 <= box.child_base + visible - 1).should be_true
  end
end
