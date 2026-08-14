require "./spec_helper"

include Crysterm

# `ensure_widget_visible` must map the descendant's top to a content-row
# index in this container's content space before calling `ensure_visible`
# (it computes from absolute tops: `child.atop - atop - itop`). Historically
# `rtop` folded the scroll area's near inset in and had to be corrected by
# `- itop`; since the spec-space `r*` redefinition (#10), a direct child's
# `rtop` IS its content-row index, with no inset to strip.
describe "Widget#ensure_widget_visible with a bordered scroll area" do
  it "reveals a descendant above the viewport, accounting for the top inset" do
    s = headless_screen(80, 24)
    box = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0,
      width: 20, height: 8, style: Crysterm::Style.new(border: true),
      content: (1..40).map { |i| "line#{i}" }.join("\n")
    child = Crysterm::Widget::Box.new parent: box, top: 10, left: 0,
      width: 5, height: 1, content: "x"
    s.repaint

    box.itop.should eq 1     # border contributes a top inset
    content_row = child.rtop # spec-space rtop: the content-row index directly
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
