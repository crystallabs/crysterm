require "./spec_helper"

include Crysterm

# Regression spec: for sub-cell backends (`Media::Glyph`, sub_w×sub_h > 1) the
# letterbox produced by `Fit::Contain`/`Cover`/`None` must meet the image on a
# whole-cell boundary.
#
# `Fitting.compose` centers the fitted image with a sub-pixel offset. When that
# offset isn't a multiple of the sub-grid, the edge cells straddle the
# image↔letterbox boundary — sampled partly image, partly transparent margin —
# and render as a dim fringe hugging the border (and flicker as a resizing box
# crosses cell parities). The fix snaps the drawn size and offset to the
# sub-grid; this asserts the resulting image bounding box lands on cell edges.

private WHITE = PNGGIF::Pixel.new(255, 255, 255, 255)

# A `w`×`h` fully-opaque source.
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

describe "Media::Fitting cell alignment (sub-cell letterbox)" do
  sub_w = 2
  sub_h = 4
  png = PNGGIF::PNG.from_frames([{opaque_src(10, 10), 0}], 10, 10)

  # A spread of box sizes, deliberately including odd cell counts (which give an
  # odd sub-pixel offset — the pre-fix straddle case) for both dimensions.
  [{14, 40}, {15, 40}, {30, 21}, {31, 22}, {40, 13}].each do |(cols, rows)|
    bw = cols * sub_w
    bh = rows * sub_h

    {Widget::Media::Fit::Contain, Widget::Media::Fit::Cover, Widget::Media::Fit::None}.each do |fit|
      it "aligns the #{fit} image to whole cells for a #{cols}x#{rows}-cell box" do
        bmp = Widget::Media::Fitting.compose(png, opaque_src(10, 10), bw, bh, fit, 1.0, sub_w, sub_h)
        bmp.should_not be_nil
        bmp = bmp.not_nil!
        bbox = opaque_bbox(bmp)
        next unless bbox # fully cropped away is fine
        left, top, right, bottom = bbox
        # Every edge of the drawn image sits on a cell boundary, so no edge cell
        # is half image / half letterbox.
        (left % sub_w).should eq 0
        (right % sub_w).should eq 0
        (top % sub_h).should eq 0
        (bottom % sub_h).should eq 0
      end
    end
  end
end
