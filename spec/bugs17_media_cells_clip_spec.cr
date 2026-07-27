require "./spec_helper"

include Crysterm

# BUGS17 B17-33 — `Media::Cells#render` ignored the ancestor clip base/origin:
# it sized/composed the sample to the *visible* slice (`cols = xl - xi`, with
# no use of `coords.base`), so an image partially scrolled out of a scrollable
# container was resampled with the WHOLE source squashed into the shrunken
# visible box instead of showing a cropped window of the full image — and
# `@rendered_size` changed on every scroll step, thrashing `@frame_cache`.
#
# Fix: compose at the FULL (unclipped) interior size — stable across scroll —
# and blit only the visible sub-rectangle, mapping through `coords.base`
# (rows) and the unclipped content origin (columns), mirroring the
# `Widget::Terminal#draw` / `Effect::Direct#paint` convention.

# Exposes the private `@rendered_size` cache key the #1 assertion is about.
private class SpyAnsi < Crysterm::Widget::Media::Ansi
  def rendered_size : Tuple(Int32, Int32)?
    @rendered_size
  end
end

private def clip_window(w = 20, h = 20)
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, optimization: Crysterm::OptimizationFlag::None)
end

# A horizontal-stripe bitmap: row *y* is a solid color keyed on *y*, so the
# row actually painted on screen can be identified by its color.
private def stripe_bmp(w : Int32, h : Int32) : PNGGIF::Bitmap
  Array.new(h) do |y|
    r = (y * 24 + 10) % 256
    Array.new(w) { PNGGIF::Pixel.new(r.to_u8, 0u8, 0u8, 255u8) }
  end
end

private def row_rgb(y : Int32) : Int32
  r = (y * 24 + 10) % 256
  Colors.rgb(r, 0, 0)
end

# The packed bg color of the top-left visible cell of *img*.
private def top_left_bg(s, img) : Int64
  lp = img.lpos.not_nil!
  cell = s.lines[lp.yi][lp.xi]
  Attr.bg(cell.attr)
end

describe "BUGS17 B17-33 Media::Cells#render clip base/origin" do
  it "composes at the full interior size and crops (not squashes) the visible slice when scrolled" do
    s = clip_window
    container = Widget::Box.new parent: s, top: 0, left: 0, width: 8, height: 6,
      scrollable: true
    img = SpyAnsi.new(parent: container, top: 0, left: 0, width: 8, height: 10,
      animate: false, fit: Crysterm::Widget::Media::Fit::Stretch)
    img.bitmap = stripe_bmp(8, 10)
    s.repaint

    # Sanity: the widget is genuinely clipped by the scrollable container
    # (taller than its viewport) from the very first render.
    lp0 = img.lpos.not_nil!
    (lp0.yl - lp0.yi).should be < 10

    # (1) The sample is composed/cached at the FULL unclipped interior size
    # (8x10), never the shrunken visible slice — this is what keeps the cache
    # stable across scroll steps instead of re-composing (and squashing) on
    # every one.
    img.rendered_size.should eq({8, 10})
    rendered_size_before_scroll = img.rendered_size

    # Scroll the container down so part of the image's top scrolls out of
    # view: `coords.base` (the clipped-off content rows) becomes > 0.
    container.child_base = 3
    s.repaint

    base = img.lpos.not_nil!.base
    base.should be > 0

    # (1, continued) Scrolling must NOT change the cache key / re-compose —
    # the full-field sample is reused as-is.
    img.rendered_size.should eq rendered_size_before_scroll
    img.rendered_size.should eq({8, 10})

    # (2) Crop, not squash: the top visible row must show the SOURCE row at
    # the scroll offset, not some resampled blend of the whole 10-row image
    # squashed into the visible band.
    top_left_bg(s, img).should eq Attr.pack_color(row_rgb(base))
  ensure
    img.try &.stop
    s.try &.destroy
  end

  it "renders an unclipped image identically to a direct same-size compose (no distortion)" do
    s = clip_window
    # No scrollable ancestor and no overflow: the widget's own box is exactly
    # its content size, so it is never clipped — the `col_off`/`row_off`
    # offsets threaded into `#draw_sample` are both 0 and `full_cols/full_rows`
    # equal the visible `cols/rows` exactly.
    img = SpyAnsi.new(parent: s, top: 0, left: 0, width: 8, height: 10,
      animate: false, fit: Crysterm::Widget::Media::Fit::Stretch)
    img.bitmap = stripe_bmp(8, 10)
    s.repaint

    lp = img.lpos.not_nil!
    (lp.yl - lp.yi).should eq 10
    img.rendered_size.should eq({8, 10})

    # Every row shows its own source color, unsquashed/uncropped.
    10.times do |y|
      cell = s.lines[lp.yi + y][lp.xi]
      Attr.bg(cell.attr).should eq Attr.pack_color(row_rgb(y))
    end
  ensure
    img.try &.stop
    s.try &.destroy
  end
end
