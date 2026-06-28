require "./spec_helper"

include Crysterm

private def mem_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Regression: `ensure_widget_visible` must map the descendant's *outer*-relative
# top (`child.rtop`, which `atop` folds the scroll area's near inset `itop` into)
# down to a content-row index before handing it to `ensure_visible`. The previous
# code passed `child.rtop` verbatim, which is correct only for an inset-less
# scroll area (`itop == 0`). With a border (so `itop == 1`) it scrolled the child
# one row too far and — when already scrolled down — failed to reveal a child
# just above the viewport top.
describe "Widget#ensure_widget_visible with a bordered scroll area" do
  it "reveals a descendant above the viewport, accounting for the top inset" do
    s = mem_screen
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0,
      width: 20, height: 8, style: Crysterm::Style.new(border: true),
      content: (1..40).map { |i| "line#{i}" }.join("\n")
    child = Crysterm::Widget::Box.new parent: box, top: 10, left: 0,
      width: 5, height: 1, content: "x"
    s._render

    box.itop.should eq 1                # border contributes a top inset
    content_row = child.rtop - box.itop # the child's true content-row index
    content_row.should eq 10

    # Scroll the viewport well past the child so it sits above the top edge.
    box.child_base = 25

    box.ensure_widget_visible(child).should be_true

    # The child's top is now within the visible content rows — not left stranded
    # one row above the viewport top by the missing-inset over-scroll.
    (box.child_base <= content_row).should be_true
    visible = box.aheight - box.iheight
    (content_row + child.aheight - 1 <= box.child_base + visible - 1).should be_true
  end
end
