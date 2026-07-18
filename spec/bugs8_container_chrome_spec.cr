require "./spec_helper"

include Crysterm

private def hscreen(w = 40, h = 20, padding = 0)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, padding: padding)
end

# BUGS8 #8 — the carousel auto-advance timer was created on Attach and stopped
# only on Destroy, with no Detach handler. A `TabWidget` `remove`d (not
# destroyed) from its window left the FrameClock timer firing `next_page` on the
# detached widget forever, pinning it alive.
describe "BUGS8 TabWidget carousel timer stops on detach (not just destroy)" do
  it "stops the timer when the widget is removed without being destroyed" do
    s = hscreen
    c = Crysterm::Widget::TabWidget.new parent: s, width: 30, height: 8, auto_advance: 50.milliseconds
    c.add_tab "A", Crysterm::Widget::Box.new(content: "a")
    c.add_tab "B", Crysterm::Widget::Box.new(content: "b")
    c.@carousel_timer.nil?.should be_false # armed while attached

    s.remove c                            # plain detach, NOT destroy
    c.@carousel_timer.nil?.should be_true # Detach handler stopped it
  end

  it "re-arms on a subsequent re-attach" do
    s = hscreen
    c = Crysterm::Widget::TabWidget.new parent: s, width: 30, height: 8, auto_advance: 50.milliseconds
    c.add_tab "A", Crysterm::Widget::Box.new(content: "a")
    s.remove c
    c.@carousel_timer.nil?.should be_true

    s.append c
    c.@carousel_timer.nil?.should be_false # Attach re-started it
  end
end

# BUGS8 #9 — the shared ToolTip is a top-level child of the window, whose
# left/top are relative to the window's content origin, but `show_at` was called
# with absolute screen coordinates and set left/top directly, double-counting
# the window's border+padding on a padded/bordered window.
describe "BUGS8 ToolTip position accounts for window insets" do
  it "places the tooltip under the pointer (content-relative), not shifted by padding" do
    s = hscreen(padding: 1)
    s.ileft.should be > 0 # padded, so the inset actually matters
    s.itop.should be > 0

    tip = Crysterm::Widget::ToolTip.new parent: s
    tip.show_at 6, 4, "hi"

    # Content-relative coordinates: subtracting the window inset undoes the
    # double-count. Pre-fix these equalled the absolute x/y (6/4).
    tip.left.should eq 6 - s.ileft
    tip.top.should eq 4 - s.itop
  end

  it "clamps to the inner size so it can't overshoot into the border/padding" do
    s = hscreen(padding: 1)
    tip = Crysterm::Widget::ToolTip.new parent: s
    # Ask to show far past the right/bottom edge: it must clamp within the inner area.
    tip.show_at 999, 999, "hi"
    w = tip.width.as(Int32)
    h = tip.height.as(Int32)
    # Inner content extent = awidth - ihorizontal (ihorizontal is the total inset).
    (tip.left.as(Int32) + w).should be <= s.awidth.not_nil! - s.ihorizontal
    (tip.top.as(Int32) + h).should be <= s.aheight.not_nil! - s.ivertical
  end
end
