require "./spec_helper"

include Crysterm

# BUGS12 #9 + #26 — `Media::ScreenOverlay` lifecycle (widget_media_screen_overlay.cr).
#
# #9: a terminal-owned graphic (sixel/Kitty/w3m) scrolled or clipped out of a
# scrollable ancestor's viewport made `coords` return nil, so
# `invalidate_old_position` early-returned and the graphic was never erased —
# it floated over the scrolled content forever (a Kitty image is a separate
# layer re-emitted cells can't cover). Unresolvable/degenerate coords must run
# the clear path exactly once, and scrolling back in must repaint.
#
# #26: the PreRender/Rendered listeners were registered on the first window
# and removed only on Destroy; the Attach/Reparent re-hooks were wired only
# when the widget was built detached. After a cross-window move the repaint
# still ran off the OLD window's Rendered event. Detach must tear the old
# window's listeners down and the next Attach must re-register on the new one,
# also for widgets constructed already attached.

private def overlay_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 20, height: 10)
end

private def red_bitmap(w = 8, h = 8)
  red = PNGGIF::Pixel.new(255, 0, 0, 255)
  Array(Array(PNGGIF::Pixel)).new(h) { Array(PNGGIF::Pixel).new(w, red) }
end

# Sixel spy exposing the shared lifecycle's private state and counting the
# erase (`overlay_cleared`) and repaint (`redraw_image`) hook invocations.
private class SpySixel < Crysterm::Widget::Media::Sixel
  getter cleared_count = 0
  getter cleared_on = [] of Crysterm::Window
  getter redraw_count = 0

  def spy_last_drawn
    @last_drawn
  end

  def spy_listener_screen
    @listener_screen
  end

  protected def overlay_cleared(s : ::Crysterm::Window)
    @cleared_count += 1
    @cleared_on << s
    super
  end

  private def redraw_image
    @redraw_count += 1
    super
  end
end

describe "BUGS12 9: overlay cleared when scrolled out of a scrollable ancestor" do
  it "clears exactly once on scroll-out and repaints on scroll-in" do
    s = overlay_screen
    outer = Widget::Box.new parent: s, top: 0, left: 0, width: 20, height: 6, scrollable: true
    # Tall spacer so the container has plenty to scroll.
    Widget::Box.new parent: outer, top: 0, left: 10, width: 1, height: 30
    img = SpySixel.new parent: outer, top: 0, left: 0, width: 6, height: 4
    img.bitmap = red_bitmap

    s._render
    img.spy_last_drawn.should_not be_nil
    img.cleared_count.should eq 0

    # Scroll the image fully out of the viewport: its coords become
    # unresolvable, which must run the clear path (erase hook + forget the
    # painted rect) so re-emitted cells / an explicit Kitty delete cover it.
    outer.scroll_to 12
    outer.child_base.should be > 0
    s._render
    img.cleared_count.should eq 1
    img.cleared_on.should eq [s]
    img.spy_last_drawn.should be_nil

    # Still scrolled out: the clear must not re-run every frame.
    s._render
    s._render
    img.cleared_count.should eq 1

    # Scroll back in: the graphic repaints (fresh painted rect).
    outer.scroll_to 0
    s._render
    img.spy_last_drawn.should_not be_nil
    img.cleared_count.should eq 1
  end
end

describe "BUGS12 26: overlay listeners migrate on a cross-window move" do
  it "re-registers on the new window and drops the old one, even when constructed attached" do
    s1 = overlay_screen
    s2 = overlay_screen
    a = Widget::Box.new parent: s1, width: "100%", height: "100%"
    b = Widget::Box.new parent: s2, width: "100%", height: "100%"

    # Constructed already attached — the re-hooks must be wired regardless.
    img = SpySixel.new parent: a, top: 0, left: 0, width: 6, height: 4
    img.bitmap = red_bitmap
    img.spy_listener_screen.should eq s1

    s1._render
    img.spy_last_drawn.should_not be_nil

    b.append img # cross-window move: Detach(s1) then Attach(s2)

    # The graphic was cleared off the OLD window, and the painted rect must
    # stay forgotten through the move (no mid-move repaint off s1's Rendered).
    img.cleared_on.should contain s1
    img.spy_last_drawn.should be_nil
    # Listeners re-registered on the new window.
    img.spy_listener_screen.should eq s2

    # The old window no longer drives this widget's repaint...
    rc = img.redraw_count
    s1._render
    img.redraw_count.should eq rc
    # ...the new one does, exactly once per render (no duplicate listeners).
    s2._render
    img.redraw_count.should eq rc + 1
    img.spy_last_drawn.should_not be_nil
  end

  it "keeps a single registration across a same-window reparent" do
    s = overlay_screen
    a = Widget::Box.new parent: s, width: "100%", height: "100%"
    b = Widget::Box.new parent: s, width: "100%", height: "100%"
    img = SpySixel.new parent: a, top: 0, left: 0, width: 6, height: 4
    img.bitmap = red_bitmap

    b.append img # same-window move: Reparent only, no Detach/Attach

    img.spy_listener_screen.should eq s
    rc = img.redraw_count
    s._render
    # Exactly one Rendered listener — a double registration would repaint twice.
    img.redraw_count.should eq rc + 1
  end
end
