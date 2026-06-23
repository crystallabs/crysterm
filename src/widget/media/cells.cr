require "./base"

module Crysterm
  class Widget
    # Abstract base for the **cell-grid** image backends — those that turn the
    # image into character cells Crysterm owns and diffs (`Media::Ansi`, one cell
    # per pixel; `Media::Glyph`, sub-cell Unicode glyphs).
    #
    # It hoists everything those two share: decoding (via `Media::Base#source`),
    # the load/animation wiring, and the resize-aware `#render` skeleton — sample
    # the source (or the current animation frame) to the content box, cache it per
    # size, and iterate the cells. Subclasses provide only the sampling resolution
    # (`#compose`) and the per-cell painting (`#draw_sample`).
    abstract class Media::Cells < Media::Base
      # Whether the loaded image is animated (its frames drive the sampled bitmap).
      @animated = false
      # Per-frame sampled bitmaps for the *current* box size, filled lazily and
      # cleared on resize (so a resize only re-samples the frames actually shown).
      @frame_cache = {} of Int32 => PNGGIF::Bitmap
      # Cell box the sample / frame cache was last built for, so resize re-samples.
      @rendered_size : Tuple(Int32, Int32)?
      # The bitmap sampled to the current box that `#draw_sample` paints from.
      @sample : PNGGIF::Bitmap?

      # (Re)decodes *file* and starts playback when it's animated. On failure,
      # shows an error string as content instead of raising.
      def load(file : String)
        stop
        @file = file
        @source = nil
        @src_frames = nil
        @frame_cache.clear
        @anim_index = 0
        @rendered_size = nil
        @sample = nil

        set_content ""
        png = source
        unless png
          set_content "Media Error: could not load #{file}"
          @animated = false
          return
        end

        @animated = !png.frames.nil? && animate?
        on_loaded png
        play if @animated
      end

      def clear_image
        super
        @animated = false
        @frame_cache.clear
        @rendered_size = nil
        set_content ""
        @sample = nil
      end

      # Streaming reuses frame index 0 with new content each tick; drop its cached
      # sample so `#render` re-samples the fresh bitmap instead of the stale one.
      protected def invalidate_frame(idx : Int32)
        @frame_cache.delete idx
      end

      # Hook: called after a successful decode (e.g. `Media::Ansi` sizes the widget
      # to the image when no explicit size was given). Default does nothing.
      protected def on_loaded(png : PNGGIF::PNG)
      end

      # Samples *img* into a bitmap for a *cols*×*rows* content box. *frame* is the
      # source frame to sample for animation, or `nil` for a still. Subclasses pick
      # the resolution (e.g. ×sub-grid) and cell aspect; see `Media::Fitting`.
      protected abstract def compose(img : PNGGIF::PNG, cols : Int32, rows : Int32,
                                     frame : PNGGIF::Bitmap?) : PNGGIF::Bitmap?

      # Paints the sampled *bmp* into the content cells `xi...xl`×`yi...yl`.
      protected abstract def draw_sample(bmp : PNGGIF::Bitmap, xi : Int32, xl : Int32, yi : Int32, yl : Int32)

      def render
        coords = _render
        return unless coords

        xi = coords.xi + ileft
        xl = coords.xl - iright
        yi = coords.yi + itop
        yl = coords.yl - ibottom

        # Resize support: (re)sample to the current content box when it changes.
        # For animation, only the *currently shown* frame is sampled (and cached
        # per size), so resizing doesn't regenerate every frame.
        if (img = source)
          cols = xl - xi
          rows = yl - yi
          if cols > 0 && rows > 0
            if @rendered_size != {cols, rows}
              @rendered_size = {cols, rows}
              @frame_cache.clear
              @sample = nil unless @animated
            end
            if @animated
              if (src = @src_frames) && (sf = src[@anim_index]?)
                frame = @frame_cache[@anim_index]?
                if frame.nil?
                  frame = compose(img, cols, rows, sf[0])
                  @frame_cache[@anim_index] = frame if frame
                end
                @sample = frame if frame
              end
            elsif @sample.nil?
              @sample = compose(img, cols, rows, nil)
            end
          end
        end

        bmp = @sample
        return coords unless bmp
        draw_sample bmp, xi, xl, yi, yl
        coords
      end
    end
  end
end
