require "./spec_helper"

include Crysterm

# Graphics per-frame churn follow-up (compose-bitmap reuse): `Fitting.compose`
# accepts caller-owned scratch canvases (`sample_into`/`place_into`) so the
# transient build→encode→discard path (`Media::Graphics#fit_bitmap` with
# `media.reuse_buffers` on) re-composes animated frames without a fresh
# resample/letterbox bitmap per frame. The reused path must stay
# pixel-identical to the allocating path — including across frames (a stale
# letterbox must not leak through) and across geometry changes (the scratches
# are resized in place, both shrinking and growing).

# A deterministic non-uniform source, so a coordinate mix-up shows up as a
# pixel difference rather than passing by uniformity.
private def gradient_src(w : Int32, h : Int32, seed : Int32 = 0) : PNGGIF::Bitmap
  Array.new(h) { |y| Array.new(w) { |x| PNGGIF::Pixel.new((x * 7 + seed) % 256, (y * 11) % 256, (x + y) % 256, 255) } }
end

private def assert_same_bitmap(a : PNGGIF::Bitmap?, b : PNGGIF::Bitmap?)
  if a.nil? || b.nil?
    a.should eq b
    return
  end
  b.size.should eq a.size
  a.each_with_index do |row, y|
    brow = b[y]
    brow.size.should eq row.size
    row.each_with_index do |px, x|
      unless brow[x] == px
        fail "pixel (#{x},#{y}) differs: #{brow[x]} vs #{px}"
      end
    end
  end
end

private FITS = [Widget::Media::Fit::Stretch, Widget::Media::Fit::Contain,
                Widget::Media::Fit::Cover, Widget::Media::Fit::None]

describe "Media::Fitting.compose scratch-canvas reuse" do
  it "is pixel-identical to the allocating path across fits and boxes" do
    src = gradient_src(20, 12)
    png = PNGGIF::PNG.from_frames([{src, 0}], 20, 12)
    sample = PNGGIF::Bitmap.new
    place = PNGGIF::Bitmap.new
    FITS.each do |fit|
      [{40, 40}, {15, 9}, {20, 12}, {64, 10}].each do |(bw, bh)|
        [true, false].each do |pixel_box|
          plain = Widget::Media::Fitting.compose(png, src, bw, bh, fit, 1.0, pixel_box: pixel_box)
          reused = Widget::Media::Fitting.compose(png, src, bw, bh, fit, 1.0, pixel_box: pixel_box,
            sample_into: sample, place_into: place)
          assert_same_bitmap plain, reused
        end
      end
    end
  end

  it "does not leak a previous frame's pixels through a letterbox margin" do
    # Frame 1 fills the whole canvas (Stretch warms every scratch cell opaque);
    # frame 2 letterboxes (Contain) — its margins must come out transparent.
    wide = gradient_src(30, 10, seed: 3)
    tall = gradient_src(10, 30, seed: 5)
    png = PNGGIF::PNG.from_frames([{wide, 0}], 30, 10)
    sample = PNGGIF::Bitmap.new
    place = PNGGIF::Bitmap.new

    Widget::Media::Fitting.compose(png, wide, 40, 40, :stretch, 1.0, pixel_box: true,
      sample_into: sample, place_into: place)
    reused = Widget::Media::Fitting.compose(png, tall, 40, 40, :contain, 1.0, pixel_box: true,
      sample_into: sample, place_into: place)
    plain = Widget::Media::Fitting.compose(png, tall, 40, 40, :contain, 1.0, pixel_box: true)
    assert_same_bitmap plain, reused
    # Belt and braces: the margin columns really are transparent.
    reused.not_nil!.first[0].a.should eq 0
  end

  it "adopts the scratches across geometry changes (shrink and grow)" do
    src = gradient_src(16, 16, seed: 9)
    png = PNGGIF::PNG.from_frames([{src, 0}], 16, 16)
    sample = PNGGIF::Bitmap.new
    place = PNGGIF::Bitmap.new
    [{48, 48}, {12, 8}, {64, 24}, {5, 5}].each do |(bw, bh)|
      plain = Widget::Media::Fitting.compose(png, src, bw, bh, :contain, 1.0, pixel_box: true)
      reused = Widget::Media::Fitting.compose(png, src, bw, bh, :contain, 1.0, pixel_box: true,
        sample_into: sample, place_into: place)
      assert_same_bitmap plain, reused
    end
  end

  it "alternating frames through the same scratches match per-frame plain composes" do
    f1 = gradient_src(20, 20, seed: 1)
    f2 = gradient_src(20, 20, seed: 200)
    png = PNGGIF::PNG.from_frames([{f1, 0}, {f2, 0}], 20, 20)
    sample = PNGGIF::Bitmap.new
    place = PNGGIF::Bitmap.new
    3.times do
      [f1, f2].each do |frame|
        plain = Widget::Media::Fitting.compose(png, frame, 33, 17, :cover, 1.0, pixel_box: true)
        reused = Widget::Media::Fitting.compose(png, frame, 33, 17, :cover, 1.0, pixel_box: true,
          sample_into: sample, place_into: place)
        assert_same_bitmap plain, reused
      end
    end
  end
end
