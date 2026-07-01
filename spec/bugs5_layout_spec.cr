require "./spec_helper"

include Crysterm

private def clip_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24, default_quit_keys: false)
end

# BUGS5 #1 — `Widget#_get_coords` bottom scroll/overflow clip must trigger at the
# clipping parent's BOTTOM border width, not its TOP border width.
#
# The clip section binds `b = sp_border.top` and (pre-fix) reused it for the
# bottom-edge trigger too. With a uniform border top == bottom this is harmless,
# but for an asymmetric border (`border-top-width: 1; border-bottom-width: 0`) a
# child sitting on the parent's last visible row (its `yl` == the parent's outer
# bottom) was compared against `parent.yl - 1` instead of `parent.yl`, so it was
# spuriously treated as fully below the viewport and dropped entirely (its `lpos`
# went nil). The fix uses a separate `bb = sp_border.bottom`.
describe "BUGS5 _get_coords bottom clip uses the parent's bottom border (fix #1)" do
  it "renders a child on the last visible row of a bottom-border-0 parent" do
    s = clip_screen
    # Asymmetric border: top 1, bottom 0. `overflow: Hidden` makes the parent a
    # clipping ancestor (child_base == 0, so the scroll math is a pure clip).
    parent = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      overflow: Overflow::Hidden,
      style: Style.new(border: Border.new(top: 1, bottom: 0, left: 0, right: 0))
    # Content region is rows 1..9 (top border eats row 0, no bottom border). A
    # child at content-row 8, height 1, lands on absolute rows [9, 10) — its `yl`
    # equals the parent's outer bottom (10).
    child = Widget::Box.new parent: parent, top: 8, left: 0, width: 20, height: 1

    s._render

    pl = parent.lpos.not_nil!
    pl.yl.should eq 10

    # The fix: the child on the last visible row is NOT dropped.
    cl = child.lpos
    cl.should_not be_nil
    cl = cl.not_nil!
    cl.yi.should eq 9
    # It reaches the parent's bottom edge (no spurious bottom clip).
    cl.yl.should eq pl.yl
  end
end

# BUGS5 #2 — the horizontal scroll/overflow clip must trigger at the parent's
# inner (border) edge, matching the vertical axis.
#
# Pre-fix the vertical clip triggered at `parent.yi + border.top` / `parent.yl -
# border.top`, but the horizontal clip triggered at the parent's OUTER edge
# (`xi < parent.xi`, `xl > parent.xl`) with no border term — even though the
# correction it applied already added `sp_border.left`/`right`. So a child at
# `left: -1` in a parent with a left border of 1 resolved to `xi == parent.xi`,
# the trigger stayed false, and the child painted over the parent's left border
# (whereas the symmetric `top: -1` WAS clipped). The fix adds `bl`/`br` to the
# horizontal triggers so they clip at the inner border edge like the vertical.
describe "BUGS5 _get_coords horizontal clip uses the parent's left/right border (fix #2)" do
  it "clips a child at left:-1 to the inner edge of a left-bordered parent" do
    s = clip_screen
    parent = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 10,
      overflow: Overflow::Hidden,
      style: Style.new(border: Border.new(top: 0, bottom: 0, left: 1, right: 0))
    # `left: -1` + the parent's left inset (1) resolves the child origin to
    # exactly `parent.xi`. Pre-fix the outer-edge trigger left it there (painting
    # over the border); the fix shifts it to the inner content edge.
    child = Widget::Box.new parent: parent, top: 0, left: -1, width: 5, height: 3

    s._render

    pl = parent.lpos.not_nil!
    cl = child.lpos
    cl.should_not be_nil
    cl = cl.not_nil!
    # The fix: the child starts at the inner border edge, not on the border.
    cl.xi.should eq pl.xi + 1
  end
end

# BUGS5 #3 — nil-height flow children and `overflow_action`.
#
# `Flow#flow_place` forces every child `resizable`, so a child with `height ==
# nil` is legal. The BUGS5 report suspected such children are measured at their
# stretched size and thus always reported as overflowing. Verified: the auto
# branch of `aheight` fills the interior *below* `el.top`, so `el.top + aheight`
# collapses to exactly the interior height for any row offset and never exceeds
# it — so a nil-height flow child is in fact NEVER reported as overflowing (the
# opposite of the report). This guards that behavior: under `overflow:
# SkipWidget`, nil-height flow children are never spuriously skipped. Reliable
# bottom-overflow detection therefore requires explicit child heights (the
# vertical analogue of the documented explicit-width requirement).
describe "BUGS5 nil-height flow children are not spuriously overflow-skipped (fix #3)" do
  it "renders nil-height Wrap children even under overflow: SkipWidget" do
    s = clip_screen
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 12,
      layout: Layout::Wrap.new, overflow: Overflow::SkipWidget
    # Explicit width, no (nil) height -> resizable/auto height. Two 8-wide
    # children share the single 20-wide row (no wrap), so both auto-fill the
    # interior height instead of collapsing on a below-interior wrapped row.
    children = Array.new(2) { Widget::Box.new parent: box, width: 8 }

    s._render

    # A skipped child has `lpos == nil` (see `Layout#skip`); had the auto-height
    # been (mis)treated as an overflow, `SkipWidget` would have nilled these.
    children.each do |c|
      cl = c.lpos
      cl.should_not be_nil                            # not skipped
      (cl.not_nil!.yl - cl.not_nil!.yi).should be > 0 # rendered at stretched height
    end
  end
end
