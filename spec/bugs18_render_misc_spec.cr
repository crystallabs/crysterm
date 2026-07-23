require "./spec_helper"

include Crysterm

# Regression specs for four BUGS18 findings:
#
# * B18-03 — `Capture.draw_cell` swapped fg/bg for a REVERSE cell while the
#   colors were still raw sentinels (`-1` = terminal default), then resolved
#   the defaults post-swap: a reversed default-colors cell captured
#   bit-identical to a non-reversed one (highlight bars, drag ghosts and
#   `{reverse}` text silently vanished from PNG/APNG captures). The defaults
#   must resolve *before* the swap, and a reversed cell must paint an opaque
#   background (covering any under-text graphics layer), as real terminals do.
#
# * B18-06 — `Screen#apply_cell_pixels` wrote per-device cell geometry into
#   the process-global CSS anchors (`divisors["px"]`, `cell_aspect_ratio`), so
#   on a multi-device app whichever terminal reported last re-anchored every
#   other window's `px` lengths. First-device-anchors policy: only the first
#   (claiming) device writes the globals; its teardown releases the claim.
#
# * B18-08 — an exception in a `FrameClock` tick block unwound the loop fiber
#   past the finalization, leaving the clock stuck `running? == true` with
#   `on_stop` never fired (contract promises it fires for *any* loop end).
#   Ticks are now isolated per invocation and finalization is in an `ensure`.
#
# * B18-09 — `Window#disable_mouse` nil'd `@_hover` without emitting
#   `MouseLeave` on the hovered widget; with reporting off no later event
#   could ever deliver it, so a visible tooltip/hover highlight stayed stale
#   forever. A synthetic leave at the last pointer position is now emitted.

private def b18_window(width = 20, height = 10)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: width, height: height)
end

private def b18_move(s, x, y)
  s.dispatch_mouse ::Tput::Mouse::Event.new(
    ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None, x, y, source: :test)
end

# A small solid-green RGBA bitmap — a color that never occurs among the
# capture defaults (black bg, silver fg), so its presence is unambiguous.
private def b18_green_bitmap(w = 8, h = 4)
  green = PNGGIF::Pixel.new(0, 255, 0, 255)
  Array(Array(PNGGIF::Pixel)).new(h) { Array(PNGGIF::Pixel).new(w, green) }
end

private def b18_has_green?(bmp)
  bmp.any? do |row|
    row.any? { |px| px.r == 0 && px.g == 255 && px.b == 0 }
  end
end

private def b18_silver?(px)
  px.r == 0xC0 && px.g == 0xC0 && px.b == 0xC0
end

describe "B18-03: Capture renders REVERSE video for terminal-default colors" do
  it "paints a reversed default-colors cell as default_fg background" do
    s = b18_window
    # No colors set: the cells carry REVERSE with both color sentinels — the
    # drag-ghost / unthemed-highlight case.
    Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 4,
      style: Crysterm::Style.new(reverse: true)

    s.repaint
    bmp = Crysterm::Capture.render(s, 0, s.awidth, 0, s.aheight)
    cw = Crysterm::BitmapFont.default_normal.width
    ch = Crysterm::BitmapFont.default_normal.height
    # Center of cell (1,1) — a blank (space) cell inside the box: reverse video
    # of default colors renders as a light (default_fg = silver) bar.
    b18_silver?(bmp[ch + ch // 2][cw + cw // 2]).should be_true
    # Control: a cell outside the box keeps the default_bg (black) canvas.
    b18_silver?(bmp[ch * 6][cw * 12]).should be_false
    bmp[ch * 6][cw * 12].r.should eq 0
  ensure
    s.try &.destroy
  end

  it "covers an under-text (negative-z) graphics layer with the reversed background" do
    s = b18_window
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 4,
      style: Crysterm::Style.new(reverse: true)
    # `fill: false` mirrors the real `background=` layer (layout-excluded
    # chrome that never paints the host's cell buffer), so the box's cells keep
    # their reversed default-colors attr.
    img = Widget::Media::Kitty.new parent: box, top: 0, left: 0, width: 8, height: 4,
      style: Crysterm::Style.new(fill: false)
    img.z = -1
    img.bitmap = b18_green_bitmap

    s.repaint
    bmp = Crysterm::Capture.render(s, 0, s.awidth, 0, s.aheight)
    # A reversed cell paints an opaque background (the resolved fg color), so
    # the under-layer must NOT show through — exactly as the terminal shows it.
    b18_has_green?(bmp).should be_false
  ensure
    s.try &.destroy
  end
end

describe "B18-06: first-device-anchors for the global CSS cell geometry" do
  it "lets only the claiming device write the global px anchor and aspect ratio" do
    Crysterm::CSS::Length.measured_source = nil
    a = b18_window
    b = b18_window
    begin
      # First device to report claims the anchor.
      a.screen.apply_cell_pixels 12, 24
      Crysterm::CSS::Length.divisors["px"].should eq 12.0
      Crysterm::CSS::Length.cell_aspect_ratio.should eq 2.0

      # A second, different device must not re-anchor the globals ...
      b.screen.apply_cell_pixels 8, 32
      Crysterm::CSS::Length.divisors["px"].should eq 12.0
      Crysterm::CSS::Length.cell_aspect_ratio.should eq 2.0
      # ... but its own per-device state is still recorded (pixel mouse, media).
      b.screen.cell_pixel_width.should eq 8
      b.screen.cell_pixel_height.should eq 32

      # The claiming device keeps tracking its own font/zoom changes.
      a.screen.apply_cell_pixels 10, 25
      Crysterm::CSS::Length.divisors["px"].should eq 10.0
      Crysterm::CSS::Length.cell_aspect_ratio.should eq 2.5
    ensure
      a.destroy
      b.destroy
      Crysterm::CSS::Length.measured_source = nil
      Crysterm::CSS::Length.divisors["px"] = 10.0
      Crysterm::CSS::Length.divisors["pt"] = 7.5
      Crysterm::CSS::Length.divisors["pc"] = 0.625
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    end
  end

  it "releases the anchor on the claiming device's teardown so a survivor takes over" do
    Crysterm::CSS::Length.measured_source = nil
    a = b18_window
    b = b18_window
    begin
      a.screen.apply_cell_pixels 12, 24
      b.screen.apply_cell_pixels 8, 16
      Crysterm::CSS::Length.divisors["px"].should eq 12.0

      # Destroying the claiming device's last window releases the claim ...
      a.destroy
      # ... so the surviving device's next report anchors the globals.
      b.screen.apply_cell_pixels 8, 16
      Crysterm::CSS::Length.divisors["px"].should eq 8.0
    ensure
      b.destroy
      Crysterm::CSS::Length.measured_source = nil
      Crysterm::CSS::Length.divisors["px"] = 10.0
      Crysterm::CSS::Length.divisors["pt"] = 7.5
      Crysterm::CSS::Length.divisors["pc"] = 0.625
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
    end
  end
end

describe "B18-08: FrameClock survives a raising tick and always finalizes" do
  it "keeps ticking after a tick raises, and stop still fires on_stop" do
    ticks = 0
    stops = 0
    clock = Crysterm::FrameClock.new(1.millisecond) do
      ticks += 1
      raise "boom" if ticks == 1
    end
    clock.on_stop { stops += 1 }

    clock.start
    sleep 30.milliseconds
    # The raising first tick must not kill the loop fiber: the clock is still
    # running (truthfully) and later ticks still fire.
    ticks.should be > 1
    clock.running?.should be_true

    clock.stop
    sleep 20.milliseconds
    # Finalization ran: `running?` is honest and `on_stop` fired exactly once.
    clock.running?.should be_false
    stops.should eq 1
  end
end

describe "B18-09: Window#disable_mouse delivers MouseLeave to the hovered widget" do
  it "emits a synthetic MouseLeave at the last pointer position" do
    s = b18_window
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 3
    leaves = 0
    lx = ly = -1
    box.on(Crysterm::Event::MouseLeave) do |e|
      leaves += 1
      lx = e.x
      ly = e.y
    end

    b18_move s, 2, 1
    s.hovered.should eq box

    s.disable_mouse
    s.hovered.should be_nil
    leaves.should eq 1
    # The synthetic leave carries the pointer's last dispatched position, not
    # a bogus (0,0).
    lx.should eq 2
    ly.should eq 1

    # Idempotent: a second disable finds no hover and emits nothing.
    s.disable_mouse
    leaves.should eq 1
  ensure
    s.try &.destroy
  end

  it "still emits no MouseLeave when the hovered widget is removed (dead-widget path)" do
    s = b18_window
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 5, height: 3
    leaves = 0
    box.on(Crysterm::Event::MouseLeave) { leaves += 1 }

    b18_move s, 2, 1
    s.hovered.should eq box

    s.remove box # removal must not fire events on the removed widget
    s.hovered.should be_nil
    leaves.should eq 0
  ensure
    s.try &.destroy
  end
end
