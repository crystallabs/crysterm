require "./spec_helper"

include Crysterm

# Focused specs for the Group E media-streaming allocation optimizations:
#
#   E1 — `Media::VideoSource::Stream` decodes each raw RGBA frame into one of two
#        preallocated ping-pong bitmaps *in place* (via `blank_bitmap` +
#        `fill_bitmap`) instead of building a fresh `Array(Array(Pixel))` per
#        frame. Two buffers, alternated, so consecutive returned frames are
#        DISTINCT objects (the downstream frame-cache identity contract), while
#        the outer/row arrays are reused (no per-frame allocation).
#   E2 — `Media::Fitting.compose` returns the resampled bitmap directly when it
#        already fills the box at the origin (no letterbox copy); the letterboxed
#        (`place_at`) path stays correct.

private alias VS = Crysterm::Widget::Media::VideoSource

# Builds a raw RGBA byte buffer for a w*h frame from a per-pixel color function.
private def rgba_buf(w, h, & : Int32, Int32 -> Tuple(Int32, Int32, Int32, Int32)) : Bytes
  buf = Bytes.new(w * h * 4)
  h.times do |y|
    w.times do |x|
      r, g, b, a = yield x, y
      i = (y * w + x) * 4
      buf[i] = r.to_u8; buf[i + 1] = g.to_u8; buf[i + 2] = b.to_u8; buf[i + 3] = a.to_u8
    end
  end
  buf
end

describe "Media::VideoSource ping-pong buffers (E1)" do
  it "blank_bitmap is correctly sized, transparent, with independent rows" do
    bmp = VS.blank_bitmap(3, 2)
    bmp.size.should eq 2
    bmp.each(&.size.should(eq(3)))
    bmp.each &.each { |px| {px.r, px.g, px.b, px.a}.should eq({0, 0, 0, 0}) }
    # Rows must be distinct objects (a value struct fill can't alias them).
    bmp[0].same?(bmp[1]).should be_false
  end

  it "fill_bitmap overwrites pixels in place, reusing the outer/row arrays" do
    bmp = VS.blank_bitmap(2, 2)
    outer_id = bmp.object_id
    row0_id = bmp[0].object_id
    row1_id = bmp[1].object_id

    buf = rgba_buf(2, 2) { |x, y| {x * 10, y * 20, x + y, 255} }
    VS.fill_bitmap bmp, buf, 2, 2

    # Same backing arrays (no allocation), new pixel contents.
    bmp.object_id.should eq outer_id
    bmp[0].object_id.should eq row0_id
    bmp[1].object_id.should eq row1_id
    {bmp[0][0].r, bmp[0][0].g, bmp[0][0].b, bmp[0][0].a}.should eq({0, 0, 0, 255})
    {bmp[1][1].r, bmp[1][1].g, bmp[1][1].b, bmp[1][1].a}.should eq({10, 20, 2, 255})
  end

  it "alternating two buffers yields distinct objects with correct per-frame content" do
    # Mirrors Stream#read_ppong: two buffers, toggled per frame.
    a = VS.blank_bitmap(2, 1)
    b = VS.blank_bitmap(2, 1)
    toggle = false
    frames = [] of PNGGIF::Bitmap
    3.times do |f|
      toggle = !toggle
      bmp = toggle ? a : b
      VS.fill_bitmap bmp, rgba_buf(2, 1) { |x, _| {f + 1, x, 0, 255} }, 2, 1
      frames << bmp
    end
    # Consecutive frames are distinct objects (frame-cache "content changed").
    frames[0].same?(frames[1]).should be_false
    frames[1].same?(frames[2]).should be_false
    # Two-buffer scheme: frame 0 and frame 2 reuse the same object.
    frames[0].same?(frames[2]).should be_true
    # Frame 2's fill overwrote the shared object, so its content is current.
    frames[2][0][0].r.should eq 3
  end
end

describe "Media::Fitting.compose exact-fit / letterbox (E2)" do
  # A small solid source bitmap.
  private_bmp = Array.new(4) { Array.new(4) { PNGGIF::Pixel.new(200, 100, 50, 255) } }

  it "Stretch fills the box exactly (early-return, correct dims and content)" do
    png = PNGGIF::PNG.from_frames([{private_bmp, 100}], 4, 4)
    out = Crysterm::Widget::Media::Fitting.compose(png, private_bmp, 6, 3,
      Crysterm::Widget::Media::Fit::Stretch)
    out.should_not be_nil
    out = out.not_nil!
    out.size.should eq 3
    out[0].size.should eq 6
    # Solid source stretches to a solid box (no transparent letterbox margin).
    out.each &.each(&.a.should(eq(255)))
  end

  it "Contain letterboxes into the box with a transparent margin (place_at path)" do
    png = PNGGIF::PNG.from_frames([{private_bmp, 100}], 4, 4)
    # A wide box: Contain pins height, leaving transparent columns left/right.
    out = Crysterm::Widget::Media::Fitting.compose(png, private_bmp, 12, 4,
      Crysterm::Widget::Media::Fit::Contain)
    out.should_not be_nil
    out = out.not_nil!
    out.size.should eq 4
    out[0].size.should eq 12
    # There must be some fully-transparent (letterbox) and some opaque cells.
    all_px = out.flatten
    all_px.any? { |px| px.a == 0 }.should be_true
    all_px.any? { |px| px.a == 255 }.should be_true
  end
end
