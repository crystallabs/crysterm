require "./spec_helper"

include Crysterm

# Regression specs for the BUGS18 scroll-clip compensation cluster in
# `Widget#coords` (B18-12, B18-15, B18-16).
#
#  B18-12 — the per-edge compensation for a clipped bordered child WIDENED the
#     final rectangle by the child's own border thickness (e.g. bottom clip:
#     `yl = parent.yl + my_border.bottom - parent_border.bottom`), so `@lpos`
#     leaked past the clipping ancestor's viewport: clicks/hover were routed to
#     the invisible band, tint/shadow painted outside the container, and a
#     dock-stop row was registered outside the clip. Now `coords` clamps the
#     rect to the viewport, records the cut in `RenderedGeometry#hidden_*`, and
#     `base_render` insets by each band's *visible* remainder
#     (`Widget#effective_edge_insets`) so painted content still ends flush with
#     the viewport edge.
#
#  B18-15 — the hidden-row fold into `base` compensated the child's border but
#     not its `padding.top`: a padded child partially scrolled above the
#     viewport skipped `padding.top` content lines and re-painted a phantom
#     padding band inside the viewport. The fold now subtracts border AND
#     padding (floored at 0), and the pre-fill bands use the effective padding.
#
#  B18-16 — with a top border thicker than the number of hidden rows the old
#     fold drove `coords.base` NEGATIVE; `Array#[]?` wraps negative indexes, so
#     the widget rendered its LAST content line at the top. The `Math.max(0, …)`
#     floor on the base advance fixes the wrap-around.

private def clip_win(w = 40, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

private def row_text(s, y, x0, x1)
  row = s.lines[y]
  String.build { |io| (x0...x1).each { |x| io << row[x].char } }
end

describe "BUGS18 B18-12: clipped lpos stays inside the ancestor's viewport" do
  it "clamps a bottom-clipped bordered child to the container's bottom edge and keeps hit-testing off the leaked row" do
    s = clip_win
    # Added BEFORE the container: pre-fix, hit_scan's last-match-wins let the
    # clipped child (whose leaked lpos claimed row 20) steal this widget's
    # clicks/hover.
    victim = Widget::Box.new parent: s, top: 20, left: 0, width: 20, height: 2
    container = Widget::Box.new parent: s, top: 0, left: 0, width: 20,
      height: 20, scrollable: true
    child = Widget::Box.new parent: container, top: 15, left: 2, width: 10,
      height: 10, content: "c0\nc1\nc2\nc3\nc4\nc5\nc6\nc7\nc8",
      style: Style.new(border: Border.new)
    # Both must be mouse-interactive for the hit-test to be meaningful: a plain
    # box is not a `widget_at` candidate (`wants_mouse?` is false). Pre-fix the
    # clickable child's leaked lpos (row 20) out-ranked the earlier-added
    # clickable victim under last-wins; post-clamp row 20 is the victim's again.
    victim.clickable = true
    child.clickable = true

    s.repaint

    cl = child.lpos.not_nil!
    # Pre-fix: yl == 21 (container bottom + child's own border.bottom).
    cl.yl.should eq 20
    cl.no_bottom?.should be_true
    cl.hidden_bottom.should eq 5

    # Content still paints flush to the viewport edge: rows 16..19 show c0..c3
    # (row 15 is the child's top border, content starts at column 3).
    row_text(s, 19, 3, 5).should eq "c3"

    # Row 20 belongs to the earlier-added victim again.
    s.widget_at(5, 20).should be(victim)
  end

  it "clamps a horizontally clipped bordered child to the parent's inner edges" do
    s = clip_win
    parent = Widget::Box.new parent: s, top: 0, left: 5, width: 10, height: 5,
      overflow: Overflow::Hidden
    child = Widget::Box.new parent: parent, top: 0, left: -3, width: 16,
      height: 3, style: Style.new(border: Border.new)

    s.repaint

    pl = parent.lpos.not_nil!
    cl = child.lpos.not_nil!
    # Pre-fix: xi == parent.xi - 1 and xl == parent.xl + 1 (widened by the
    # child's own left/right border).
    cl.xi.should eq pl.xi
    cl.xl.should eq pl.xl
    cl.no_left?.should be_true
    cl.no_right?.should be_true
  end

  it "keeps a bordered child of a clipped bordered container inside the grandparent's viewport (nested clipping)" do
    s = clip_win
    gp = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      overflow: Overflow::Hidden
    # The container's own bottom border band is fully clipped away by `gp`, so
    # its inner bottom edge IS its lpos edge — children must clip there, not
    # one border-width past it.
    container = Widget::Box.new parent: gp, top: 4, left: 0, width: 15,
      height: 10, scrollable: true, style: Style.new(border: Border.new)
    child = Widget::Box.new parent: container, top: 0, left: 0, width: 10,
      height: 12, style: Style.new(border: Border.new)

    s.repaint

    container.lpos.not_nil!.yl.should eq 10
    cl = child.lpos.not_nil!
    # Pre-fix the bordered child leaked one row past the grandparent's
    # viewport (yl == 11).
    cl.yl.should eq 10
  end
end

describe "BUGS18 B18-15: partial-top clip compensates the child's padding" do
  # Scrollable parent viewport rows 10..19; child with `padding.top = 2`, no
  # border, content line0..line19.
  it "skips only hidden CONTENT lines when more rows than the padding are hidden" do
    s = clip_win
    par = Widget::Box.new parent: s, top: 10, left: 0, width: 20, height: 10,
      scrollable: true
    child = Widget::Box.new parent: par, top: 0, left: 0, width: 20, height: 22,
      content: (0..19).join("\n") { |i| "line#{i}" }
    child.style.padding.top = 2
    par.child_base = 3

    s.repaint

    cl = child.lpos.not_nil!
    cl.yi.should eq 10
    cl.hidden_top.should eq 3
    # 3 hidden rows = 2 padding rows + 1 content line. Pre-fix base == 3: two
    # content lines were unreachable and a 2-row phantom padding band painted.
    cl.base.should eq 1
    row_text(s, 10, 0, 5).should eq "line1"
    row_text(s, 11, 0, 5).should eq "line2"
  end

  it "keeps base at 0 and shows the padding remainder when fewer rows than the padding are hidden" do
    s = clip_win
    par = Widget::Box.new parent: s, top: 10, left: 0, width: 20, height: 10,
      scrollable: true
    child = Widget::Box.new parent: par, top: 0, left: 0, width: 20, height: 22,
      content: (0..19).join("\n") { |i| "line#{i}" }
    child.style.padding.top = 2
    par.child_base = 1

    s.repaint

    cl = child.lpos.not_nil!
    cl.yi.should eq 10
    # Only padding rows are hidden — no content line is. Pre-fix base == 1
    # (line0 lost) with a full 2-row phantom band.
    cl.base.should eq 0
    # One padding row remains visible, then content from line0.
    row_text(s, 10, 0, 5).should eq "     "
    row_text(s, 11, 0, 5).should eq "line0"
  end
end

describe "BUGS18 B18-16: partial-top clip never drives base negative (thick border)" do
  it "renders the FIRST content line, not the last, when fewer rows than the top border are hidden" do
    s = clip_win
    par = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      scrollable: true
    child = Widget::Box.new parent: par, top: 0, left: 0, width: 12, height: 6,
      content: "line1\nline2\nline3",
      style: Style.new(border: Border.new(top: 2, bottom: 0, left: 0, right: 0))
    # Gives the parent a real scroll extent past the viewport.
    Widget::Box.new parent: par, top: 6, left: 0, width: 4, height: 10
    par.child_base = 1

    s.repaint

    cl = child.lpos.not_nil!
    cl.yi.should eq 0
    # Pre-fix: base == -1 → `@_clines.ci[-1]?` wrapped to the LAST line's
    # offset and "line3" painted at the top of the viewport.
    cl.base.should eq 0
    cl.hidden_top.should eq 1
    # Row 0 holds the (skipped) remainder of the border band — parent
    # background, never content; content starts one row in, shifted up by
    # exactly the 1 scrolled row.
    row_text(s, 0, 0, 5).should eq "     "
    row_text(s, 1, 0, 5).should eq "line1"
    row_text(s, 2, 0, 5).should eq "line2"
    row_text(s, 3, 0, 5).should eq "line3"
  end
end
