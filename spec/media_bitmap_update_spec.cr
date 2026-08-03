require "./spec_helper"

include Crysterm

# Regression spec for `Media::Graphics#reset_sample_cache`.
#
# `Media::Base#bitmap=` replaces the source content without changing box
# geometry and calls `#reset_sample_cache` to drop per-size derived caches.
# `Media::Cells` overrides that hook, and `Media::Graphics` (sixel/Kitty/
# iTerm/ReGIS) must too — its `#payload_for` cache is keyed only on geometry,
# so with the inherited no-op base version a same-size live update keeps
# serving the previous frame's encoded payload, freezing the graphic on a
# stale image. The override clears that cache (and emit-tracking keys) so the
# next render re-encodes the new bitmap.

private def solid(r, g, b, w = 4, h = 4) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(r, g, b, 255) } }
end

# Extract the in-band sixel payload (DCS … ST) from emitted terminal bytes.
private def sixel_of(bytes : String) : String?
  start = bytes.index("\eP") || return
  fin = bytes.index("\e\\", start) || return
  bytes[start..(fin + 1)]
end

describe "Media::Graphics#reset_sample_cache (live bitmap= update)" do
  it "re-encodes the payload when the bitmap is replaced at the same size" do
    s = headless_screen(80, 24, default_quit_keys: true)
    img = Crysterm::Widget::Media::Sixel.new(
      parent: s, top: 0, left: 0, width: 10, height: 4)

    buf = s.output.as(IO::Memory)

    # Frame 1: a solid red bitmap.
    img.bitmap = solid(255, 0, 0)
    buf.clear
    s.repaint
    red_payload = sixel_of(buf.to_s)
    red_payload.should_not be_nil

    # Frame 2: same box, different content. Without the override the
    # geometry-keyed cache would re-emit the red payload verbatim.
    img.bitmap = solid(0, 0, 255)
    buf.clear
    s.repaint
    blue_payload = sixel_of(buf.to_s)
    blue_payload.should_not be_nil

    blue_payload.should_not eq red_payload
  ensure
    img.try &.stop
    s.try &.destroy
  end
end
