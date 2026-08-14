require "./spec_helper"

include Crysterm

# Regression specs for the BUGS15 layout-engine fixes (#3, #31, #33, #34, #4,
# #32). Headless harness mirrors spec/bugs12_layout_spec.cr.

private def rendered_height(el)
  l = el.lpos.not_nil!
  l.yl - l.yi
end

# BUGS15 #3 — Layout::Border must not destroy a percent consume-axis size
# (frozen at frame 1's cells) nor make a transient clamp permanent.
# Originally guarded by raw/assigned shadow maps; since the layout-geometry
# split (plans/SIZE-POLICY-PLAN.md §2.2) the engine never touches the child's
# specs at all, and these pin that structural guarantee.
describe "BUGS15 border layout keeps the child-owned consume axis (fix #3)" do
  it "re-resolves a top child's percent height against the live container" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 20,
      layout: Layout::Border.new
    top = Widget::Box.new parent: box, height: "50%",
      layout_hint: Layout::Border::Hint.new(:top)
    Widget::Box.new parent: box # center

    s.repaint
    rendered_height(top).should eq 10 # 50% of 20

    # Shrink the container: the percent must re-resolve, not stay frozen at
    # the frame-1 cells written back over the "50%" string.
    box.height = 10
    s.repaint
    rendered_height(top).should eq 5 # 50% of 10
  end

  it "does not make a transient clamp of an Int height sticky" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 40, height: 20,
      layout: Layout::Border.new
    top = Widget::Box.new parent: box, height: 8,
      layout_hint: Layout::Border::Hint.new(:top)
    Widget::Box.new parent: box # center

    s.repaint
    rendered_height(top).should eq 8

    # Squeeze so the edge clamps to the remaining span, then grow back.
    box.height = 5
    s.repaint
    rendered_height(top).should eq 5 # clamped

    box.height = 20
    s.repaint
    rendered_height(top).should eq 8 # restored, not stuck at the clamp
  end
end

# BUGS15 #31 — Border must subtract edge-child margins on the span axis too:
# reserving only the consume axis assigns a margined edge child the full span
# which, after coords' near shift, paints past the container.
describe "BUGS15 border layout reserves the span-axis margin (fix #31)" do
  it "keeps a left-margined top bar inside the container's right edge" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 80, height: 10,
      layout: Layout::Border.new
    header = Widget::Box.new parent: box, height: 1,
      layout_hint: Layout::Border::Hint.new(:top),
      style: Style.new(margin: Margin.new(left: 2, top: 0, right: 0, bottom: 0))
    Widget::Box.new parent: box # center

    s.repaint

    hl = header.lpos.not_nil!
    bl = box.lpos.not_nil!
    # Assigned the full 80-col span, the header would shift right by its 2-col
    # left margin and paint columns 80-81 outside the container.
    hl.xl.should be <= (bl.xl - box.iright)
  end
end

# BUGS15 #33 — Grid::Hint column origin clamps to `cols - 1`, landing an
# off-grid child in the last column (symmetric with the negative-col clamp to
# column 0) — clamping to `cols` (one past the last valid column) collapses
# it to zero width past the interior.
describe "BUGS15 grid clamps an off-grid column to the last column (fix #33)" do
  it "renders a col-beyond-grid child in the last column, not vanished" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 30, height: 10,
      layout: Layout::Grid.new(columns: 3, spacing: 0)
    Widget::Box.new parent: box,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 0)
    off = Widget::Box.new parent: box,
      layout_hint: Layout::Grid::Hint.new(row: 0, column: 5) # column >= columns

    s.repaint

    # Guards against: width 0, left 30 (past the interior), lpos nil.
    # `awidth`/`rleft`: the assignment lives in the layout-geometry channel;
    # the child's own specs stay nil.
    off.lpos.should_not be_nil
    off.awidth.should eq 10 # last of three 10-wide columns
    off.rleft.should eq 20  # column 2 origin
  end
end

# BUGS15 #34 — Flow#overflow_action must count the child's top margin: a
# margin-shifted box overflowing the interior bottom would otherwise go
# unreported and the container's SkipWidget/StopRendering policy never engage.
describe "BUGS15 flow overflow accounts for the child's top margin (fix #34)" do
  it "skips a bottom-overflowing child once its top margin is counted" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 5,
      layout: Layout::Wrap.new, overflow: :skip_widget
    child = Widget::Box.new parent: box, width: 4, height: 5,
      style: Style.new(margin: Margin.new(left: 0, top: 1, right: 0, bottom: 0))

    s.repaint

    # 0 + mtop(1) + aheight(5) = 6 > 5 interior -> SkipWidget -> lpos cleared.
    # Without mtop (0 + 5 > 5 is false) it would render a row past the bottom.
    child.lpos.should be_nil
  end
end

# BUGS15 #4 — Flow must not chain placement solely off the previous *rendered*
# child: a scroll-clipped child has a nil lpos, so once the top rows scroll
# out of view every later child falls back to (0,0) and clips too, blanking
# the whole container. Placement chains off a placed-but-unrendered
# predecessor's geometry and advances the row cursor by its assigned height.
describe "BUGS15 flow keeps scrolled rows visible (fix #4)" do
  it "shows the scrolled-into-view rows instead of re-piling at the origin" do
    s = headless_screen(80, 24)
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 12, height: 6,
      layout: Layout::Wrap.new, overflow: :ignore, scrollable: true
    20.times { Widget::Box.new parent: box, width: 3, height: 2 }

    s.repaint
    box.scroll_to 7
    box.child_base.should eq 2 # two content rows scrolled above the viewport
    s.repaint

    kids = box.children
    # Row 0 (children 0-3) is scrolled fully above the viewport.
    kids[0].lpos.should be_nil
    # Row 1 (children 4-7) is now the top visible row: it must actually render
    # and stay staggered across the row, not collapse every child onto (0,0).
    kids[4].lpos.should_not be_nil
    kids[7].lpos.should_not be_nil
    kids[4].rleft.should eq 0
    kids[7].rleft.should eq 9 # 4th column, proving the chain didn't collapse
    kids[4].rtop.should eq 2  # row cursor advanced past the clipped row
  end
end

# BUGS15 #32 — Layout::Form must not treat any non-Int32 height as 1 nor write
# the resolved row height back into each child, destroying a percent/String
# height and making the paired-row max sticky. String heights resolve via
# aheight, mirroring Border's release bookkeeping.
describe "BUGS15 form resolves and preserves child heights (fix #32)" do
  it "resolves a field's percent height instead of collapsing it to 1" do
    s = headless_screen(80, 24)
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 60, height: 30,
      layout: Layout::Form.new
    label = Widget::Box.new parent: form, height: 5
    field = Widget::Box.new parent: form, height: "30%"

    s.repaint
    # row height = max(5, 30% of 30 = 9) = 9; a "30%" -> 1 collapse would give 5.
    rendered_height(field).should eq 9
    rendered_height(label).should eq 9

    # Shrink the form: the percent must re-resolve (30% of 10 = 3), so the row
    # falls back to the label's 5 instead of staying frozen.
    form.height = 10
    s.repaint
    rendered_height(field).should eq 5
  end

  it "un-sticks the paired-row max after the partner shrinks" do
    s = headless_screen(80, 24)
    form = Widget::Box.new parent: s, top: 0, left: 0, width: 60, height: 30,
      layout: Layout::Form.new
    label = Widget::Box.new parent: form, height: 5
    field = Widget::Box.new parent: form, height: 3

    s.repaint
    rendered_height(field).should eq 5 # max(5, 3)

    # Shrink the label: the row must shrink to the field's 3 — the field's raw
    # 3 must not be overwritten with the frame-1 max (5), pinning the row at 5.
    label.height = 1
    s.repaint
    rendered_height(field).should eq 3 # max(1, 3)
  end
end
