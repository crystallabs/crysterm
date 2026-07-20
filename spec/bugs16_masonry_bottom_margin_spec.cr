require "./spec_helper"

include Crysterm

# Regression spec for BUGS16 #18. Headless harness mirrors
# spec/bugs15_layout_margins_spec.cr.

private def headless_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def margin(left = 0, top = 0, right = 0, bottom = 0)
  Style.new(margin: Margin.new(left: left, top: top, right: right, bottom: bottom))
end

# BUGS16 #18 — Layout::Masonry#gravitate_up set `el.top = alp.yl - yi`, flush
# against the above child's drawn bottom edge, without adding that child's
# bottom margin. The wrap path (`flow_place`'s `row_tallest`) is margin-correct
# — it advances `@row_offset` by `lp.height + el.mvertical` — but gravitation
# then overwrote that margin-correct top, collapsing the margin to zero.
describe "BUGS16 18: Masonry gravitation respects the above child's bottom margin" do
  it "keeps a wrapped child below the above child's bottom margin, not glued to it" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 12,
      layout: Layout::Masonry.new
    a = Widget::Box.new parent: box, width: 12, height: 3, style: margin(bottom: 2)
    b = Widget::Box.new parent: box, width: 12, height: 3

    s._render

    al = a.lpos.not_nil!
    bl = b.lpos.not_nil!
    # A renders at yi=0..yl=3. B wraps (row offset correctly advanced to
    # 3+2=5 by flow_place/row_tallest) but pre-fix gravitation overwrote its
    # top back to 3, gluing it directly under A and collapsing the 2-row
    # bottom margin. Post-fix B must start at yi=5, respecting the margin.
    al.yi.should eq 0
    al.yl.should eq 3
    bl.yi.should eq 5
    bl.yl.should eq 8
  end

  it "still gravitates flush when the above child has no bottom margin" do
    s = headless_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 12,
      layout: Layout::Masonry.new
    a = Widget::Box.new parent: box, width: 12, height: 3
    b = Widget::Box.new parent: box, width: 12, height: 3

    s._render

    al = a.lpos.not_nil!
    bl = b.lpos.not_nil!
    # No margin: gravitation still glues B flush under A (unchanged behavior).
    al.yl.should eq 3
    bl.yi.should eq 3
  end
end
