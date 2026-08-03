require "./spec_helper"

include Crysterm

# Regression specs for BUGS16 B16-17 — Layout::Form resolved each pair's column
# width and wrote the Int back over the child's raw `@width` with no
# bookkeeping. On the next arrange `measured_label_width` saw the assigned Int
# and returned it instead of re-measuring content, so an auto (`label_width:
# nil`) column froze at frame 1's widest content and a label's own raw
# `nil`/`String` width was destroyed. Restoring each child's raw width
# *before* the column is measured mirrors the height bookkeeping
# (@raw_width/@assigned_width).

private def rendered_width(el)
  l = el.lpos.not_nil!
  l.xl - l.xi
end

describe "BUGS16 B16-17 Form auto label column re-derives across frames" do
  it "widens the auto column when a label's content grows" do
    s = headless_screen(80, 24)
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 60, height: 30,
      layout: Layout::Form.new
    label = Widget::Box.new parent: form, height: 1, content: "Name"
    Widget::Box.new parent: form, height: 1

    s.repaint
    rendered_width(label).should eq 4 # "Name"

    label.set_content "A much longer label"
    s.repaint
    # Without restoring the raw width the column would stay frozen at 4,
    # clipping the label; restoring it re-measures to 19.
    rendered_width(label).should eq 19
  end

  it "shrinks the auto column when a label's content shrinks" do
    s = headless_screen(80, 24)
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 60, height: 30,
      layout: Layout::Form.new
    label = Widget::Box.new parent: form, height: 1, content: "A much longer label"
    Widget::Box.new parent: form, height: 1

    s.repaint
    rendered_width(label).should eq 19

    label.set_content "Hi"
    s.repaint
    # Without restoring the raw width the column would stay stuck at 19;
    # restoring it re-measures to 2.
    rendered_width(label).should eq 2
  end

  it "keeps a label's non-Int32 raw width from freezing the column to an Int" do
    s = headless_screen(80, 24)
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 60, height: 30,
      layout: Layout::Form.new
    # A String width is not the explicit-Int32 case, so the column tracks the
    # label's content: without restoring the raw width, the "50%" would be
    # overwritten by the assigned Int on the first arrange and the column
    # would never re-derive.
    label = Widget::Box.new parent: form, height: 1, width: "50%", content: "Name"
    Widget::Box.new parent: form, height: 1

    s.repaint
    rendered_width(label).should eq 4

    label.set_content "A much longer label"
    s.repaint
    rendered_width(label).should eq 19
  end

  it "still honours an explicit Int32 label width every frame (no regression)" do
    s = headless_screen(80, 24)
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 60, height: 30,
      layout: Layout::Form.new
    label = Widget::Box.new parent: form, height: 1, width: 10, content: "Name"
    Widget::Box.new parent: form, height: 1

    s.repaint
    rendered_width(label).should eq 10

    # A longer content does not widen an explicitly-sized label's column.
    label.set_content "A much longer label"
    s.repaint
    rendered_width(label).should eq 10
  end
end
