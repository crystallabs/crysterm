require "./spec_helper"

include Crysterm

# Regression specs for two BUGS16 findings:
#
# * B16-51 — `Capture.render` always composited terminal-native graphics
#   layers OVER the text-cell pass, regardless of stacking (`z`). A Kitty
#   placement with negative `z` (the `background=`/CSS `background-image`
#   case) is drawn UNDER the cell text by the terminal, so a capture must
#   composite it before the text pass — and `draw_cell` must skip its
#   background fill for a terminal-default-background cell, or the (always
#   opaque) fill would still bury the under-layer.
#
# * B16-52 — `Media::Sixel#dither=` was a plain `property`: the encoded sixel
#   payload is memoized per animation frame (`Media::Graphics#payload_for`,
#   keyed on geometry only, not dither), so a runtime dither change silently
#   kept re-emitting the stale cached bytes until an unrelated resize/move.

private def cap_window
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 20, height: 10)
end

# A small solid-green RGBA bitmap — a color that never occurs among the
# capture defaults (black bg, silver fg) or the blue concrete background used
# below, so its presence is unambiguous.
private def green_bitmap(w = 8, h = 4)
  green = PNGGIF::Pixel.new(0, 255, 0, 255)
  Array(Array(PNGGIF::Pixel)).new(h) { Array(PNGGIF::Pixel).new(w, green) }
end

private def capture_has_green?(bmp)
  bmp.any? do |row|
    row.any? { |px| px.r == 0 && px.g == 255 && px.b == 0 }
  end
end

describe "B16-51: Capture stacks negative-z Kitty layers under the text" do
  it "hides a background (negative-z) layer under a cell with a concrete background color" do
    s = cap_window
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 4,
      style: Crysterm::Style.new(bg: 0x0000ff)
    # `fill: false` mirrors the real `background=` layer: it is `layout_excluded`
    # chrome that never paints the host's own cell buffer (widget_background.cr),
    # so the box's own concrete bg fill is the last (and only) writer of these
    # cells. `capture_layer` below reads the widget's geometry directly, not the
    # cell buffer, so this doesn't affect its own compositing.
    img = Widget::Media::Kitty.new parent: box, top: 0, left: 0, width: 8, height: 4,
      style: Crysterm::Style.new(fill: false)
    img.z = -1
    img.bitmap = green_bitmap

    s.repaint
    bmp = Crysterm::Capture.render(s, 0, s.awidth, 0, s.aheight)
    # The concrete blue background must win, exactly as the terminal shows it
    # (background= draws under text but is still hidden by a concrete bg).
    capture_has_green?(bmp).should be_false
  ensure
    s.try &.destroy
  end

  it "shows a background (negative-z) layer through a cell with the terminal-default background" do
    s = cap_window
    img = Widget::Media::Kitty.new parent: s, top: 0, left: 0, width: 8, height: 4
    img.z = -1
    img.bitmap = green_bitmap

    s.repaint
    bmp = Crysterm::Capture.render(s, 0, s.awidth, 0, s.aheight)
    capture_has_green?(bmp).should be_true
  ensure
    s.try &.destroy
  end

  it "keeps an on-top (default z) layer visible over a cell with a concrete background" do
    s = cap_window
    box = Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 4,
      style: Crysterm::Style.new(bg: 0x0000ff)
    img = Widget::Media::Kitty.new parent: box, top: 0, left: 0, width: 8, height: 4
    img.bitmap = green_bitmap

    s.repaint
    bmp = Crysterm::Capture.render(s, 0, s.awidth, 0, s.aheight)
    capture_has_green?(bmp).should be_true
  ensure
    s.try &.destroy
  end
end

private def sixel_window(w = 40, h = 12)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: w, height: h)
end

# A left-to-right red gradient — sensitive enough to the dither mode
# (Diffusion vs None) that the two encode to different sixel RLE bytes.
private def gradient_bitmap(w : Int32, h : Int32) : PNGGIF::Bitmap
  Array(Array(PNGGIF::Pixel)).new(h) do
    Array(PNGGIF::Pixel).new(w) { |x| PNGGIF::Pixel.new((x * 255 // (w - 1)).to_u8, 0u8, 0u8, 255u8) }
  end
end

# Exposes the private per-frame payload cache so the drop can be pinned
# directly, mirroring `KittyProbe` in bugs15_media_graphics_spec.cr.
private class SixelProbe < Crysterm::Widget::Media::Sixel
  def probe_payload_geom
    @payload_geom
  end

  def probe_frame_payloads
    @frame_payloads
  end

  def probe_emitted_key
    @emitted_key
  end
end

describe "B16-52: Media::Sixel#dither= invalidates the cached payload" do
  it "drops the payload cache and emit key on a real dither change" do
    s = sixel_window
    img = SixelProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    img.bitmap = gradient_bitmap(40, 60)
    s.repaint

    img.probe_payload_geom.should_not be_nil
    img.probe_frame_payloads.empty?.should be_false
    img.probe_emitted_key.should_not be_nil

    img.dither = Crysterm::Widget::Media::Dither::None
    img.probe_payload_geom.should be_nil
    img.probe_frame_payloads.empty?.should be_true
    img.probe_emitted_key.should be_nil
  ensure
    s.try &.destroy
  end

  it "leaves the cache intact on a no-op dither assignment" do
    s = sixel_window
    img = SixelProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    img.bitmap = gradient_bitmap(40, 60)
    s.repaint
    img.probe_payload_geom.should_not be_nil

    img.dither = img.dither # already Auto — must not churn the cache
    img.probe_payload_geom.should_not be_nil
  ensure
    s.try &.destroy
  end

  it "re-encodes with the new dither mode on the next render instead of replaying stale bytes" do
    s = sixel_window
    img = SixelProbe.new parent: s, top: 0, left: 0, width: 4, height: 3
    img.bitmap = gradient_bitmap(40, 60)
    s.repaint
    first = img.probe_frame_payloads[0]?
    first.should_not be_nil

    img.dither = Crysterm::Widget::Media::Dither::None
    s.repaint
    second = img.probe_frame_payloads[0]?
    second.should_not be_nil

    # Pre-fix: the plain `property` setter drops nothing, so `payload_for`
    # keeps serving the geometry-keyed cache entry built under the old
    # dither mode — the second render re-emits byte-identical bytes.
    second.should_not eq first
  ensure
    s.try &.destroy
  end
end
