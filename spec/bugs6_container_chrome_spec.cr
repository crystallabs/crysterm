require "./spec_helper"

include Crysterm

# Regression specs for BUGS6 section 4 (container & window-chrome widgets).
#
#  BUG 1 (src/widget/dock_widget.cr, #current_float_rect + #wire_drag Drag):
#     a child's `left`/`top` are relative to the parent's *content* origin
#     (`widget_position.cr` adds `parent.ileft`/`itop`), but both the float-geometry
#     capture and the drag handler subtracted only the parent's outer `aleft`/`atop`,
#     dropping `ileft`/`itop`. Inside a bordered/padded parent this jumped the dock
#     right/down by the inset on float-in-place, and made a drag track the pointer
#     with a constant offset. Now the parent's content origin (`aleft + ileft`,
#     `atop + itop`) is used in both places.
#
#  BUG 2 (src/widget/dock_widget.cr, #wire_drag Drag): the drag clamp bounded
#     `left`/`top` against the parent's *outer* size, letting a floating dock be
#     dragged out over the parent's border/padding. Now it clamps against the
#     parent's content extent (`awidth - ihorizontal`, `aheight - ivertical`).
#
#  BUG 3 (src/widget/status_bar.cr, #draw_permanent): on overflow the right-aligned
#     permanent text was truncated on the *right*, cutting the most recently added
#     sections while keeping the leftmost. It now drops the *left* end so the tail
#     stays visible.

private def chrome_win
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# A parent Box with a 1-cell border all around, giving it an inner inset
# (`ileft == itop == 1`, `ihorizontal == ivertical == 2`) so the content-origin math matters.
private def bordered_parent(s)
  p = Crysterm::Widget::Box.new parent: s, left: 3, top: 2, width: 40, height: 20
  p.style.border = Crysterm::Border.new # defaults to 1 on every side
  p
end

private def row_text(s, y, x0, x1)
  row = s.lines[y]
  String.build { |io| (x0...x1).each { |x| io << row[x].char } }
end

describe "BUGS6 DockWidget drag/float coordinate frame (bug 1)" do
  it "keeps the dock's absolute position when floating in place inside a bordered parent" do
    s = chrome_win
    parent = bordered_parent s
    dock = Crysterm::Widget::DockWidget.new parent: parent, title: "D",
      area: Crysterm::Widget::DockWidget::Area::Left,
      left: 5, top: 3, width: 12, height: 6
    s._render

    before_l = dock.aleft
    before_t = dock.atop
    parent.ileft.should eq 1 # sanity: the parent really has an inner inset
    parent.itop.should eq 1

    # Undock in place: freezes the current rect as float geometry. The absolute
    # position must not move (the old code shifted it by parent.ileft/itop).
    dock.toggle_floating restore: false
    dock.floating?.should be_true
    s._render

    dock.aleft.should eq before_l
    dock.atop.should eq before_t
  end

  it "tracks the pointer exactly while dragging inside a bordered parent" do
    s = chrome_win
    parent = bordered_parent s
    dock = Crysterm::Widget::DockWidget.new parent: parent, title: "D",
      area: Crysterm::Widget::DockWidget::Area::Floating,
      left: 4, top: 3, width: 12, height: 6
    s._render

    tb = dock.titlebar
    data = Crysterm::DragData.new tb
    # Grab the dock's own top-left corner (drag_dx/dy == 0).
    session = Crysterm::DragSession.new tb, data, dock.aleft, dock.atop, Crysterm::DragSensor::Mouse
    tb.emit Crysterm::Event::DragStart.new(session)

    # Move the pointer to a spot well within the parent's content area.
    target_x = parent.aleft + parent.ileft + 3
    target_y = parent.atop + parent.itop + 2
    session.x = target_x
    session.y = target_y
    tb.emit Crysterm::Event::Drag.new(session)

    # Grabbed at the corner, so the dock's corner must land exactly on the pointer
    # (the old code was off by parent.ileft/itop).
    dock.aleft.should eq target_x
    dock.atop.should eq target_y
  end
end

describe "BUGS6 DockWidget drag clamp bounds (bug 2)" do
  it "clamps a far drag to the parent's content extent, not its outer size" do
    s = chrome_win
    parent = bordered_parent s
    dock = Crysterm::Widget::DockWidget.new parent: parent, title: "D",
      area: Crysterm::Widget::DockWidget::Area::Floating,
      left: 4, top: 3, width: 12, height: 6
    s._render

    tb = dock.titlebar
    data = Crysterm::DragData.new tb
    session = Crysterm::DragSession.new tb, data, dock.aleft, dock.atop, Crysterm::DragSensor::Mouse
    tb.emit Crysterm::Event::DragStart.new(session)

    # Drag far past the bottom-right; the clamp must pin it inside the content box.
    session.x = 10_000
    session.y = 10_000
    tb.emit Crysterm::Event::Drag.new(session)

    # Content extent = outer size minus the inset; max left/top leaves room for
    # the dock. The looser (buggy) bound would be parent.awidth - dock.awidth.
    dock.left.should eq(parent.awidth - parent.ihorizontal - dock.awidth)
    dock.top.should eq(parent.aheight - parent.ivertical - dock.aheight)
  end
end

describe "BUGS6 StatusBar right-aligned overflow (bug 3)" do
  it "keeps the tail (most recent sections) visible and drops the left end" do
    s = chrome_win
    bar = Crysterm::Widget::StatusBar.new parent: s, top: 0, left: 0, width: 12, height: 1
    bar.add_permanent "AAAA"
    bar.add_permanent "BBBB"
    bar.add_permanent "CCCC" # joined text (18 cells) overflows the 12-wide bar
    s._render

    line = row_text s, 0, 0, 12
    line.includes?("CCCC").should be_true  # newest section survives
    line.includes?("AAAA").should be_false # oldest (leftmost) section is dropped
  end

  it "right-aligns permanent text that fits without truncation" do
    s = chrome_win
    bar = Crysterm::Widget::StatusBar.new parent: s, top: 0, left: 0, width: 12, height: 1
    bar.add_permanent "OK" # fits: right-aligned against the bar's right edge
    s._render

    row_text(s, 0, 0, 12).should eq "          OK"
  end
end
