require "./spec_helper"

include Crysterm

# `Media::Fitting.source_size` caps an animation's source frames to `cap` on the
# long edge, deriving the short edge by `short * cap // long`. That integer
# division used to have no minimum, so an aspect ratio steeper than `cap:1`
# floored the short edge to 0 — e.g. a 4000x10 banner GIF yielded `{200, 0}`.
# A 0-sized source resample (`animation_cellmaps(w, 0, ...)`) builds empty
# frames, so such a source drew nothing. The short edge is now clamped to >= 1,
# as its siblings (`Fit::None`, `cap_size`) already do.

private WHITE = PNGGIF::Pixel.new(255, 255, 255, 255)

private def ss_src(w : Int32, h : Int32) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w, WHITE) }
end

describe "Media::Fitting.source_size" do
  it "keeps both dimensions >= 1 for an extreme wide/short aspect ratio" do
    png = PNGGIF::PNG.from_frames([{ss_src(4000, 10), 0}], 4000, 10)
    w, h = Widget::Media::Fitting.source_size(png)
    w.should eq 200  # long edge capped
    h.should be >= 1 # short edge no longer floored to 0
  end

  it "keeps both dimensions >= 1 for an extreme tall/thin aspect ratio" do
    png = PNGGIF::PNG.from_frames([{ss_src(10, 4000), 0}], 10, 4000)
    w, h = Widget::Media::Fitting.source_size(png)
    w.should be >= 1 # short edge no longer floored to 0
    h.should eq 200  # long edge capped
  end

  it "leaves a within-cap image untouched" do
    png = PNGGIF::PNG.from_frames([{ss_src(120, 80), 0}], 120, 80)
    Widget::Media::Fitting.source_size(png).should eq({120, 80})
  end
end
