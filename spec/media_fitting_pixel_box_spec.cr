require "./spec_helper"

include Crysterm

# Regression spec for BUGS12 #10: on the in-band pixel-graphics backends
# (`Media::Graphics` — Sixel/ReGIS/Kitty/iTerm), `Fitting.compose` receives
# true device pixels as the box, so `Fit::None` must draw the source at its
# **native 1:1 pixel size** — not the cell-footprint conversion (÷ cell aspect
# ratio) the cell/sub-cell backends need, which squashed the image to half its
# height. The `pixel_box` flag scopes that to `Fit::None` only: every scaling
# fit, and every cell-backend call shape, must be byte-identical to before.

private WHITE = PNGGIF::Pixel.new(255, 255, 255, 255)

private def opaque_src(w : Int32, h : Int32) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w, WHITE) }
end

# Bounding box {left, top, right_exclusive, bottom_exclusive} of the opaque
# (alpha > 0) region of a composed bitmap, or nil if fully transparent.
private def opaque_bbox(bmp : PNGGIF::Bitmap)
  left = top = Int32::MAX
  right = bottom = -1
  bmp.each_with_index do |row, y|
    row.each_with_index do |px, x|
      next if px.a == 0
      left = x if x < left
      right = x + 1 if x + 1 > right
      top = y if y < top
      bottom = y + 1 if y + 1 > bottom
    end
  end
  right < 0 ? nil : {left, top, right, bottom}
end

private def compose_bbox(png, src, bw, bh, fit, am = 1.0, sw = 1, sh = 1, pixel_box = false)
  bmp = Widget::Media::Fitting.compose(png, src, bw, bh, fit, am, sw, sh, pixel_box)
  bmp.should_not be_nil
  opaque_bbox(bmp.not_nil!)
end

describe "Media::Fitting pixel-box (device-pixel graphics backends)" do
  png = PNGGIF::PNG.from_frames([{opaque_src(100, 100), 0}], 100, 100)
  src = opaque_src(100, 100)
  png_wide = PNGGIF::PNG.from_frames([{opaque_src(100, 60), 0}], 100, 60)
  src_wide = opaque_src(100, 60)
  none = Widget::Media::Fit::None

  it "draws Fit::None at native 1:1 device pixels, centered (was 2:1 squashed)" do
    # 12x6-cell widget at 10x20 px cells => a 120x120 px box.
    compose_bbox(png, src, 120, 120, none, pixel_box: true)
      .should eq({10, 10, 110, 110}) # 100x100 px — not 100x50
    compose_bbox(png_wide, src_wide, 120, 120, none, pixel_box: true)
      .should eq({10, 30, 110, 90}) # 100x60 px native
  end

  it "still center-crops a Fit::None source larger than the box" do
    # 100x100 source into a 60x40 px box: centered => offsets (-20, -30),
    # the fully-opaque middle fills the whole box.
    compose_bbox(png, src, 60, 40, none, pixel_box: true)
      .should eq({0, 0, 60, 40})
  end

  it "leaves the scaling fits byte-identical with pixel_box set" do
    {Widget::Media::Fit::Stretch, Widget::Media::Fit::Contain, Widget::Media::Fit::Cover}.each do |fit|
      [{100, 100, 120, 120}, {100, 60, 120, 120}, {100, 100, 60, 40}].each do |(sw, sh, bw, bh)|
        p = PNGGIF::PNG.from_frames([{opaque_src(sw, sh), 0}], sw, sh)
        s = opaque_src(sw, sh)
        with_pb = Widget::Media::Fitting.compose(p, s, bw, bh, fit, 1.0, 1, 1, true)
        without = Widget::Media::Fitting.compose(p, s, bw, bh, fit, 1.0, 1, 1, false)
        with_pb.should eq without
      end
    end
  end

  it "pins the Graphics scaling-fit output (values from before the pixel_box change)" do
    contain = Widget::Media::Fit::Contain
    cover = Widget::Media::Fit::Cover
    # 100x60 contained in 120x120 px: 120x72 letterboxed at oy=24.
    compose_bbox(png_wide, src_wide, 120, 120, contain, pixel_box: true)
      .should eq({0, 24, 120, 96})
    # 100x100 contained in 60x40 px: 40x40 centered at ox=10.
    compose_bbox(png, src, 60, 40, contain, pixel_box: true)
      .should eq({10, 0, 50, 40})
    # Cover always fills the box.
    compose_bbox(png_wide, src_wide, 120, 120, cover, pixel_box: true)
      .should eq({0, 0, 120, 120})
  end

  it "keeps the cell-backend Fit::None footprint unchanged (Ansi and Glyph call shapes)" do
    prev = Crysterm::CSS::Length.cell_aspect_ratio
    begin
      Crysterm::CSS::Length.cell_aspect_ratio = 2.0
      # Ansi: bw/bh are cells, aspect_mul = cell aspect, sub 1x1 — a 100x100 px
      # source occupies 100x50 cells.
      compose_bbox(png, src, 120, 120, none, 2.0)
        .should eq({10, 35, 110, 85})
      # Glyph octant (2x4 sub-grid, aspect_mul = car*sx/sy = 1.0): same
      # 100x50-cell footprint, expressed in sub-pixels (200x200).
      compose_bbox(png, src, 120*2, 120*4, none, 1.0, 2, 4)
        .should eq({20, 140, 220, 340})
    ensure
      Crysterm::CSS::Length.cell_aspect_ratio = prev
    end
  end
end
