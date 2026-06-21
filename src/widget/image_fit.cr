module Crysterm
  class Widget
    # Shared image-resampling used by every image backend to support rendering
    # into a box of *varying* size. The key idea (see each backend): keep the
    # decoded image as a resolution-independent **source** (`PNGGIF::PNG`, whose
    # `bmp` is the full-res bitmap) and derive a box-sized render from it on
    # demand, so a resize re-samples rather than re-decoding the file.
    #
    # `compose` resamples the source into a `bw`×`bh` bitmap, fit per `Image::Fit`,
    # leaving any letterbox margin fully transparent (`a == 0`) so the backends
    # can skip/keep it. *aspect_mul* corrects for non-square output cells: pixel
    # backends pass `1.0`; `ANSIImage` passes its `cell_aspect` (a cell is ~2×
    # taller than wide); `GlyphImage` passes `1.0` because its sub-grid already
    # makes sub-pixels square.
    module ImageFitting
      TRANSPARENT = PNGGIF::Pixel.new(0, 0, 0, 0)

      def self.compose(src : PNGGIF::PNG, bw : Int32, bh : Int32,
                       fit : Image::Fit, aspect_mul : Float64 = 1.0) : PNGGIF::Bitmap?
        return nil if bw <= 0 || bh <= 0
        sw = src.width
        sh = src.height
        return nil if sw <= 0 || sh <= 0

        dw, dh, ox, oy = fit.layout(bw, bh, (sw * aspect_mul).round.to_i, sh)
        sampled = src.create_cellmap(src.bmp, cmwidth: dw, cmheight: dh, cell_aspect: 1.0)
        return nil if sampled.empty?

        # Stretch that already fills the box exactly: hand back the sample as-is.
        if fit.stretch? && sampled.size == bh && (sampled[0]?.try(&.size) || 0) == bw
          return sampled
        end

        out = Array(Array(PNGGIF::Pixel)).new(bh) { Array.new(bw, TRANSPARENT) }
        sampled.each_with_index do |srow, y|
          ty = y + oy
          next if ty < 0 || ty >= bh
          orow = out[ty]
          srow.each_with_index do |px, x|
            tx = x + ox
            next if tx < 0 || tx >= bw
            orow[tx] = px
          end
        end
        out
      end
    end
  end
end
