require "pnggif"
require "./widget_media_fit"

module Crysterm
  class Widget
    # Shared image-resampling used by every image backend to support rendering
    # into a box of *varying* size. The key idea (see each backend): keep the
    # decoded image as a resolution-independent **source** (`PNGGIF::PNG`, whose
    # `bmp` is the full-res bitmap) and derive a box-sized render from it on
    # demand, so a resize re-samples rather than re-decoding the file.
    #
    # `compose` resamples the source into a `bw`×`bh` bitmap, fit per `Media::Fit`,
    # leaving any letterbox margin fully transparent (`a == 0`) so the backends
    # can skip/keep it. *aspect_mul* corrects for non-square output cells: pixel
    # backends pass `1.0`; `Media::Ansi` passes its `cell_aspect` (a cell is ~2×
    # taller than wide); `Media::Glyph` passes `1.0` because its sub-grid already
    # makes sub-pixels square.
    module Media::Fitting
      TRANSPARENT = PNGGIF::Pixel.new(0, 0, 0, 0)

      # Cap (long edge, px) for the composited *animation* source frames. A
      # terminal box is at most a few hundred sub-pixels wide, so compositing 34×
      # full-res frames of a large GIF is wasted work and memory; capping keeps
      # quality effectively identical for any terminal box while cutting the
      # (eager) build cost and per-frame memory. Stills keep their full-res source.
      ANIM_SOURCE_CAP = 200

      # Capped `{w, h}` to composite animation source frames at, preserving aspect.
      def self.source_size(png : PNGGIF::PNG, cap : Int32 = ANIM_SOURCE_CAP) : Tuple(Int32, Int32)
        cw = png.canvas_width
        ch = png.canvas_height
        cw = png.width if cw <= 0
        ch = png.height if ch <= 0
        return {cw, ch} if cw <= cap && ch <= cap
        cw >= ch ? {cap, (ch * cap // cw)} : {(cw * cap // ch), cap}
      end

      # Convenience: fit a PNG's own (still) bitmap.
      def self.compose(src : PNGGIF::PNG, bw : Int32, bh : Int32,
                       fit : Media::Fit, aspect_mul : Float64 = 1.0,
                       sub_w : Int32 = 1, sub_h : Int32 = 1) : PNGGIF::Bitmap?
        compose src, src.bmp, bw, bh, fit, aspect_mul, sub_w, sub_h
      end

      # Fit an arbitrary full-resolution *src_bmp* (e.g. a composited animation
      # frame) into a *bw*×*bh* box, resampling via *png*'s nearest-neighbour
      # `create_cellmap`. Letterbox margins are left fully transparent.
      #
      # *bw*/*bh* are in the caller's sampling units. For a sub-cell backend
      # (`Media::Glyph`) those are *sub-pixels* — `cols*sub_w` × `rows*sub_h` — so
      # `sub_w`/`sub_h` tell `Fit::None` how many sub-pixels make one terminal
      # cell. That lets 1:1 size the image by its *terminal-cell* footprint
      # (sub-grid-independent), so switching ascii/half/quadrant/sextant/octant
      # changes only the detail, never the size.
      def self.compose(png : PNGGIF::PNG, src_bmp : PNGGIF::Bitmap, bw : Int32, bh : Int32,
                       fit : Media::Fit, aspect_mul : Float64 = 1.0,
                       sub_w : Int32 = 1, sub_h : Int32 = 1) : PNGGIF::Bitmap?
        return nil if bw <= 0 || bh <= 0
        sh = src_bmp.size
        sw = sh > 0 ? src_bmp[0].size : 0
        return nil if sw <= 0 || sh <= 0

        # 1:1 — draw at the source's native *terminal-cell* footprint, centered/
        # cropped. The footprint uses the terminal's measured cell aspect ratio
        # (cell height ÷ width, auto-detected from the reported pixel size / CSS
        # config — see `CSS::Length.cell_aspect_ratio`), independent of the backend
        # and of the Glyph sub-grid; the sub-grid only multiplies it up into
        # sub-pixels. So every backend/sub-mode shows the image at the SAME size;
        # finer sub-grids merely resolve more detail within it. (Separate from the
        # ratio fits below, which fill the box and are already size-stable.)
        if fit.none?
          car = Crysterm::CSS::Length.cell_aspect_ratio
          car = 2.0 if car <= 0
          fcw = sw                             # footprint cells wide  (1 px/cell)
          fch = {(sh / car).round.to_i, 1}.max # footprint cells tall  (cell h÷w)
          tw = {fcw * sub_w, 1}.max            # → sub-pixels for this backend
          th = {fch * sub_h, 1}.max
          sampled = png.create_cellmap(src_bmp, cmwidth: tw, cmheight: th, cell_aspect: 1.0)
          return place_centered(sampled, bw, bh)
        end

        dw, dh, ox, oy = fit.layout(bw, bh, (sw * aspect_mul).round.to_i, sh)
        sampled = png.create_cellmap(src_bmp, cmwidth: dw, cmheight: dh, cell_aspect: 1.0)
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

      # Centers *src* (its own size) into a *bw*×*bh* transparent canvas, cropping
      # any overflow (so an over-size 1:1 image shows its middle). Returns nil if
      # *src* is empty.
      def self.place_centered(src : PNGGIF::Bitmap, bw : Int32, bh : Int32) : PNGGIF::Bitmap?
        return nil if src.empty?
        nh = src.size
        nw = src[0]?.try(&.size) || 0
        return nil if nw <= 0
        out = Array(Array(PNGGIF::Pixel)).new(bh) { Array.new(bw, TRANSPARENT) }
        oy0 = (bh - nh) // 2
        ox0 = (bw - nw) // 2
        src.each_with_index do |srow, y|
          ty = y + oy0
          next if ty < 0 || ty >= bh
          orow = out[ty]
          srow.each_with_index do |px, x|
            tx = x + ox0
            next if tx < 0 || tx >= bw
            orow[tx] = px
          end
        end
        out
      end
    end
  end
end
