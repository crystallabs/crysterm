require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 #16. Headless harness mirrors
# spec/bugs15_scrolling_chrome_spec.cr.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# BUGS16 #16 — the whole `Layout::Flow` family (Wrap/Masonry/UniformGrid) only
# guarded `layout_excluded?`, not `layout_chrome?`, so a border label or bound
# scroll bar was arranged as flow child 0: `flow_place` overwrote its pinned
# left/top, it consumed a slot and wrapped the real children, and its
# full-interior awidth inflated the UniformGrid column and the flow row heights.
# This is BUGS15 #20 fixed for the `each_arrangeable` engines but missed here.
describe "BUGS16 16: Flow engines do not arrange border-label/scrollbar chrome" do
  it "keeps a Wrap-container's border label on the border row, not in a slot" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 12,
      layout: Layout::Wrap.new, style: Style.new(border: true)
    box.set_label "Settings"
    lbl = box.label_widget.not_nil!

    c1 = Widget::Box.new parent: box, width: 5, height: 2
    c2 = Widget::Box.new parent: box, width: 5, height: 2

    s.repaint

    box.itop.should eq 1
    lbl.layout_chrome?.should be_true

    # The label stays pinned to the border row (top == -itop). Pre-fix it was
    # arranged into interior slot 0 at top 0 / left 0.
    lbl.top.should eq(-box.itop)
    lbl.lpos.should_not be_nil # still painted out-of-band

    bl = box.lpos.not_nil!
    interior_top = bl.yi + box.itop
    interior_left = bl.xi + box.ileft

    # First real child sits at the interior origin — the label consumed no slot
    # and did not push it to a second row.
    c1.lpos.not_nil!.yi.should eq interior_top
    c1.lpos.not_nil!.xi.should eq interior_left
    # Second child chains beside the first on the same row (label awidth did not
    # inflate the chain predecessor into a wrap).
    c2.lpos.not_nil!.yi.should eq interior_top
  end

  it "does not let a border label inflate a UniformGrid's column width" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 12,
      layout: Layout::UniformGrid.new, style: Style.new(border: true)
    box.set_label "A very very long settings label"

    c1 = Widget::Box.new parent: box, width: 5, height: 2
    c2 = Widget::Box.new parent: box, width: 5, height: 2

    s.repaint

    # Pre-fix the label's full-interior awidth became the uniform column width,
    # collapsing the grid to one column so c2 wrapped to a second row. Post-fix
    # both 5-wide children share the first row.
    c1.lpos.not_nil!.yi.should eq c2.lpos.not_nil!.yi
    c2.lpos.not_nil!.xi.should be > c1.lpos.not_nil!.xi
  end

  it "keeps a Masonry-container's border label on the border row, not in a slot" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 12,
      layout: Layout::Masonry.new, style: Style.new(border: true)
    box.set_label "Settings"
    lbl = box.label_widget.not_nil!

    c1 = Widget::Box.new parent: box, width: 5, height: 2
    c2 = Widget::Box.new parent: box, width: 5, height: 2

    s.repaint

    lbl.top.should eq(-box.itop) # pinned to border row, not arranged to a slot

    bl = box.lpos.not_nil!
    interior_top = bl.yi + box.itop
    interior_left = bl.xi + box.ileft

    # Both children flow from the interior origin — the label as child 0 neither
    # consumed a slot nor (via its full-interior awidth) wrapped c2 to a row down.
    c1.lpos.not_nil!.yi.should eq interior_top
    c1.lpos.not_nil!.xi.should eq interior_left
    c2.lpos.not_nil!.yi.should eq interior_top
  end
end
