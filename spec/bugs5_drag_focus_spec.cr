require "./spec_helper"

include Crysterm

# Regression specs for the BUGS5 drag / focus fixes.
#
#  BUG 1 (src/window_drag.cr, `#drag_nudge`): a keyboard reposition accumulated
#  the virtual anchor (`sess.x`/`sess.y`) with no clamp, while the reposition
#  handler clamps the widget's `left`/`top` to the parent bounds. Once the widget
#  was pinned at an edge, every further arrow in that direction still pushed the
#  anchor past the edge, so the user had to unwind that overshoot before the
#  widget moved back — input appeared dead for N presses. `#drag_nudge` now
#  re-syncs the anchor to the source's actual (clamped) position each nudge.
#
#  BUG 2 (src/window_focus.cr, `#_focus`): scroll-into-view for a newly focused
#  widget must map the descendant into the scrollable ANCESTOR's content frame.
#  The old hand-rolled math used `cur.rtop` (relative to the immediate parent),
#  wrong when a non-scrollable container sits between `cur` and the scrollable
#  ancestor. The fix delegates to `#ensure_widget_visible`, which uses absolute
#  tops (`cur.atop - el.atop - el.itop`). This is a guard spec: the fix was
#  already present in the working tree.

private def bugs5_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def keypress(char : Char, key : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, key
end

describe "BUGS5 keyboard-drag anchor does not drift past an edge (fix #1)" do
  it "responds immediately to a reversing arrow after being pinned at the left edge" do
    s = bugs5_screen
    # Placed flush against the left edge; nudging Left keeps it pinned at 0.
    box = Crysterm::Widget::Box.new parent: s, left: 0, top: 5,
      width: 8, height: 4, draggable: true, keys: true
    box.focus

    # Lift it (Space) and push Left several times; the widget is already pinned.
    s._drag_key_handled(keypress(' ')).should be_true
    3.times { s._drag_key_handled(keypress('\0', ::Tput::Key::Left)).should be_true }
    box.left.should eq 0

    # A single Right must move it right away. With the unbounded-anchor bug, the
    # anchor had drifted to -3, so this Right only unwinds the overshoot and the
    # widget stays pinned at 0.
    s._drag_key_handled(keypress('\0', ::Tput::Key::Right)).should be_true
    box.left.should eq 1
  end

  it "responds immediately to a reversing arrow after being pinned at the top edge" do
    s = bugs5_screen
    box = Crysterm::Widget::Box.new parent: s, left: 5, top: 0,
      width: 8, height: 4, draggable: true, keys: true
    box.focus

    s._drag_key_handled(keypress(' ')).should be_true
    3.times { s._drag_key_handled(keypress('\0', ::Tput::Key::Up)).should be_true }
    box.top.should eq 0

    s._drag_key_handled(keypress('\0', ::Tput::Key::Down)).should be_true
    box.top.should eq 1
  end

  it "keeps the session anchor in lockstep with the pinned widget" do
    s = bugs5_screen
    box = Crysterm::Widget::Box.new parent: s, left: 0, top: 5,
      width: 8, height: 4, draggable: true, keys: true
    box.focus

    s._drag_key_handled(keypress(' ')).should be_true
    sess = s.drag_session.not_nil!

    # offset_x is 0 for a keyboard pickup (anchor == source top-left), so the
    # re-synced anchor equals the source's clamped aleft.
    5.times { s._drag_key_handled(keypress('\0', ::Tput::Key::Left)) }
    box.left.should eq 0
    sess.x.should eq(box.aleft + sess.offset_x)
  end
end

describe "BUGS5 focus scroll-into-view through a non-scrollable container (guard #2)" do
  it "scrolls a deep descendant into the scrollable ancestor's viewport on focus" do
    s = bugs5_screen
    scroll = Crysterm::Widget::ScrollableBox.new parent: s, top: 0, left: 0,
      width: 20, height: 8
    # A plain, non-scrollable container sitting at a non-zero offset between the
    # scrollable ancestor and the focus target — this is what makes `cur.rtop`
    # (immediate-parent frame) disagree with the ancestor's content frame.
    container = Crysterm::Widget::Box.new parent: scroll, top: 5, left: 0,
      width: 18, height: 40
    child = Crysterm::Widget::Box.new parent: container, top: 30, left: 0,
      width: 5, height: 1, keys: true, content: "x"
    s.repaint

    # The child's true row in the scroll area's content frame folds in BOTH the
    # container offset (5) and the child's own top (30) — not just `child.rtop`.
    content_row = child.atop - scroll.atop - scroll.itop + scroll.child_base
    content_row.should eq 35

    scroll.child_base.should eq 0 # below the viewport, not yet revealed

    child.focus

    # Focusing scrolls it into view: the viewport now includes the child's
    # content row (35). We compare against `content_row` — not a value
    # recomputed from `child.atop` after the scroll — because absolute positions
    # are only refreshed on the next render, so `child.atop` is still stale here.
    scroll.child_base.should_not eq 0
    visible = scroll.visible_content_rows
    (scroll.child_base <= content_row).should be_true
    (content_row <= scroll.child_base + visible - 1).should be_true
  end
end
