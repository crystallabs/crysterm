require "pnggif"

module Crysterm
  class Widget
    module Media
      # How an image is fit into a box whose aspect ratio differs from the
      # image's — shared by every backend so the behaviour is consistent.
      enum Fit
        Stretch # fill the box exactly, distorting aspect ratio (default)
        Contain # scale to fit inside the box, letterboxing the remainder
        Cover   # scale to fill the box, cropping the overflow
        None    # draw at the source's native 1:1 size, centered (cropped if larger than the box)

        # Lays an image of *sw*×*sh* into a *bw*×*bh* box, returning the drawn
        # size and top-left offset `{dw, dh, ox, oy}` (offsets are negative for
        # `Cover`/`None`, where the image is larger than the box and gets cropped).
        def layout(bw : Int32, bh : Int32, sw : Int32, sh : Int32) : Tuple(Int32, Int32, Int32, Int32)
          # 1:1 — keep the source's own pixel size, centered in the box.
          return {sw, sh, (bw - sw) // 2, (bh - sh) // 2} if none? && sw > 0 && sh > 0
          return {bw, bh, 0, 0} if stretch? || sw <= 0 || sh <= 0 || bw <= 0 || bh <= 0
          ar = sw.to_f / sh.to_f
          box_ar = bw.to_f / bh.to_f
          # Pin height (derive width) when the box is "wider" than the image for
          # Contain, or "taller" for Cover; pin width otherwise.
          pin_height = contain? ? (box_ar > ar) : (box_ar < ar)
          if pin_height
            dh = bh
            dw = (bh * ar).round.to_i
          else
            dw = bw
            dh = (dw / ar).round.to_i
          end
          dw = 1 if dw < 1
          dh = 1 if dh < 1
          {dw, dh, (bw - dw) // 2, (bh - dh) // 2}
        end
      end
    end

    # Shared image-resampling used by every image backend to render into a box
    # of *varying* size. Keeps the decoded image as a resolution-independent
    # **source** (`PNGGIF::PNG`, whose `bmp` is the full-res bitmap) and derives
    # a box-sized render from it on demand, so a resize re-samples rather than
    # re-decoding the file.
    #
    # `compose` resamples the source into a `bw`×`bh` bitmap, fit per
    # `Media::Fit`, leaving any letterbox margin fully transparent (`a == 0`).
    # *aspect_mul* corrects for non-square output cells: pixel backends pass
    # `1.0`; `Media::Ansi` passes its `cell_aspect` (a cell is ~2× taller than
    # wide); `Media::Glyph` passes `1.0` since its sub-grid already makes
    # sub-pixels square.
    module Media::Fitting
      TRANSPARENT = PNGGIF::Pixel.new(0, 0, 0, 0)

      # Cap (long edge, px) for composited *animation* source frames. A terminal
      # box is at most a few hundred sub-pixels wide, so compositing full-res
      # frames of a large GIF wastes work/memory; capping keeps quality
      # effectively identical while cutting build cost. Stills keep full-res source.
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

      # Fit either a specific animation *frame* (when non-nil) or *png*'s own
      # still bitmap into a *bw*×*bh* box — folding the `frame ? … : …` source
      # pick each backend used to open-code.
      def self.compose(png : PNGGIF::PNG, frame : PNGGIF::Bitmap?, bw : Int32, bh : Int32,
                       fit : Media::Fit, aspect_mul : Float64 = 1.0,
                       sub_w : Int32 = 1, sub_h : Int32 = 1) : PNGGIF::Bitmap?
        compose png, frame || png.bmp, bw, bh, fit, aspect_mul, sub_w, sub_h
      end

      # Fit an arbitrary full-resolution *src_bmp* (e.g. a composited animation
      # frame) into a *bw*×*bh* box, resampling via *png*'s nearest-neighbour
      # `create_cellmap`. Letterbox margins are left fully transparent.
      #
      # *bw*/*bh* are in the caller's sampling units. For a sub-cell backend
      # (`Media::Glyph`) those are *sub-pixels* (`cols*sub_w` × `rows*sub_h`), so
      # `sub_w`/`sub_h` tell `Fit::None` how many sub-pixels make one terminal
      # cell — letting 1:1 size the image by its terminal-cell footprint, so
      # switching ascii/half/quadrant/sextant/octant changes only detail, never size.
      def self.compose(png : PNGGIF::PNG, src_bmp : PNGGIF::Bitmap, bw : Int32, bh : Int32,
                       fit : Media::Fit, aspect_mul : Float64 = 1.0,
                       sub_w : Int32 = 1, sub_h : Int32 = 1) : PNGGIF::Bitmap?
        return nil if bw <= 0 || bh <= 0
        sh = src_bmp.size
        sw = sh > 0 ? src_bmp[0].size : 0
        return nil if sw <= 0 || sh <= 0

        # 1:1 — draw at the source's native terminal-cell footprint, centered/
        # cropped. Uses the terminal's measured cell aspect ratio (height ÷
        # width, auto-detected — see `CSS::Length.cell_aspect_ratio`), independent
        # of backend/sub-grid; the sub-grid only multiplies it into sub-pixels.
        # So every backend/sub-mode shows the image at the same size; finer
        # sub-grids just resolve more detail within it.
        if fit.none?
          car = Crysterm::CSS::Length.cell_aspect_ratio
          car = 2.0 if car <= 0
          fcw = sw                             # footprint cells wide  (1 px/cell)
          fch = {(sh / car).round.to_i, 1}.max # footprint cells tall  (cell h÷w)
          tw = {fcw * sub_w, 1}.max            # → sub-pixels for this backend
          th = {fch * sub_h, 1}.max
          sampled = png.create_cellmap(src_bmp, cmwidth: tw, cmheight: th, cell_aspect: 1.0)
          return nil if sampled.empty?
          nh = sampled.size
          nw = sampled[0]?.try(&.size) || 0
          # Center on a whole-cell boundary (see the letterbox note below).
          return place_at sampled, bw, bh, snap((bw - nw) // 2, sub_w), snap((bh - nh) // 2, sub_h)
        end

        dw, dh, ox, oy = fit.layout(bw, bh, (sw * aspect_mul).round.to_i, sh)

        # Align the drawn image to whole terminal cells (sub-cell backends only,
        # where sub_w/sub_h > 1). Otherwise the image↔letterbox boundary can land
        # in the middle of an edge cell, which then samples partly image and
        # partly transparent margin and paints as a dim fringe hugging the whole
        # border — visible along the top/bottom or left/right edge, and flickering
        # as a resizing box crosses cell parities. Snapping the size and offset to
        # the sub-grid makes every edge cell fall wholly inside or outside the
        # image, so letterbox meets image on a clean cell boundary. Stretch fills
        # exactly (no margin) and 1:1 backends have sub == 1, so both are untouched.
        unless fit.stretch?
          dw = {snap(dw, sub_w), sub_w}.max
          dh = {snap(dh, sub_h), sub_h}.max
          ox = snap(ox, sub_w)
          oy = snap(oy, sub_h)
        end

        sampled = png.create_cellmap(src_bmp, cmwidth: dw, cmheight: dh, cell_aspect: 1.0)
        return nil if sampled.empty?

        # Stretch that already fills the box exactly: hand back the sample as-is.
        if fit.stretch? && sampled.size == bh && (sampled[0]?.try(&.size) || 0) == bw
          return sampled
        end

        place_at sampled, bw, bh, ox, oy
      end

      # Rounds *v* to the nearest multiple of *s* (the sub-cell grid step), so a
      # letterbox size/offset lands on a whole-cell boundary. A no-op for the
      # 1:1 backends (`s == 1`). Handles negatives (a `Cover` crop offset) via
      # symmetric rounding.
      private def self.snap(v : Int32, s : Int32) : Int32
        return v if s <= 1
        (v.to_f / s).round.to_i * s
      end

      # Centers *src* (its own size) into a *bw*×*bh* transparent canvas, cropping
      # any overflow (so an over-size 1:1 image shows its middle). Returns nil if
      # *src* is empty.
      def self.place_centered(src : PNGGIF::Bitmap, bw : Int32, bh : Int32) : PNGGIF::Bitmap?
        return nil if src.empty?
        nh = src.size
        nw = src[0]?.try(&.size) || 0
        return nil if nw <= 0
        place_at src, bw, bh, (bw - nw) // 2, (bh - nh) // 2
      end

      # Copies *src* into a fresh *bw*×*bh* fully-transparent canvas at pixel
      # offset (*ox*, *oy*), clipping anything outside the canvas. Shared by the
      # fit (`#compose`) and 1:1 centering (`#place_centered`) paths.
      private def self.place_at(src : PNGGIF::Bitmap, bw : Int32, bh : Int32,
                                ox : Int32, oy : Int32) : PNGGIF::Bitmap
        out = Array(Array(PNGGIF::Pixel)).new(bh) { Array.new(bw, TRANSPARENT) }
        src.each_with_index do |srow, y|
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
