require "./widget_media_base"

module Crysterm
  class Widget
    # Abstract base for the **cell-grid** image backends — those that turn the
    # image into character cells Crysterm owns and diffs (`Media::Ansi`, one cell
    # per pixel; `Media::Glyph`, sub-cell Unicode glyphs).
    #
    # Hoists everything those two share: decoding (via `Media::Base#source`),
    # load/animation wiring, and the resize-aware `#render` skeleton — sample
    # the source (or current animation frame) to the content box, cache it per
    # size, and iterate the cells. Subclasses provide only the sampling
    # resolution (`#compose`) and the per-cell painting (`#draw_sample`).
    abstract class Media::Cells < Media::Base
      # Memoizes a value derived from the *whole* current sample bitmap (e.g. a
      # dithered colour plane, a luminance threshold), keyed by **animation frame
      # index** (parallel to `@frame_cache`) and identity-validated against the
      # bitmap it was computed for. The expensive whole-bitmap pass runs once per
      # composed frame and is reused on every later render of that frame — so a
      # looping GIF that cycles N distinct frame bitmaps hits per frame instead of
      # thrashing on every frame change (as a single-slot memo keyed only on the
      # current bitmap would). A still uses index 0, where its stable `@sample`
      # gives the same reuse a single-slot memo would.
      #
      # The identity check keeps it correct even if a frame index is reused with
      # new content (streaming video pins index 0): the derived value is dropped
      # when its bitmap no longer matches, and the owning `Media::Cells` also
      # clears the matching entry wherever it clears `@frame_cache` (resize,
      # reload, `bitmap=`/`reset_sample_cache`, streaming `invalidate_frame`).
      # Memory is bounded by the frame count `@frame_cache` already accepts.
      # Shared by `Media::Ansi` and `Media::Glyph`.
      class FrameMemo(T)
        @cache = {} of Int32 => Tuple(PNGGIF::Bitmap, T)

        def get(idx : Int32, bmp : PNGGIF::Bitmap, & : -> T) : T
          if (entry = @cache[idx]?) && entry[0].same?(bmp)
            return entry[1]
          end
          val = yield
          @cache[idx] = {bmp, val}
          val
        end

        # Drops every frame's derived value (a full resample: resize/reload/reset).
        def clear : Nil
          @cache.clear
        end

        # Drops just frame *idx*'s derived value (its composed frame changed).
        def delete(idx : Int32) : Nil
          @cache.delete idx
        end
      end

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
        # Clear the failure latch so a new file is actually attempted — otherwise
        # `#source` early-returns nil forever after any prior failed load (its own
        # documented contract: "Reset on new file load").
        @load_failed = false
        @src_frames = nil
        @frame_cache.clear
        clear_frame_derived
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

        # Only a *genuine* (multi-frame) animation drives the frame loop. A
        # single-frame source whose `frames` is nonetheless non-nil — e.g. a
        # 1-frame APNG (`build_apng_frames` returns its lone frame, unlike a GIF
        # which leaves `frames` nil below 2 frames) — must be treated as a
        # still: `Media::Base#play` bails on a single frame (never building
        # `@src_frames`), so an errantly-set `@animated` would leave `#render`'s
        # animation branch with no frames and nothing drawn. Matching `#play`'s
        # `> 1` guard routes such a source through the still path instead.
        fr = png.frames
        # A live *streaming* video also needs `@animated` true even though its
        # `source` only ever exposes a 1-frame vehicle: `Media::Base#play`
        # plays whenever `@stream` is set, and `#render`'s animation branch
        # reads the per-tick `@src_frames` slot the stream fills. Without this,
        # the video would stay static with its ffmpeg subprocess left unread.
        @animated = ((!fr.nil? && fr.size > 1) || !@stream.nil?) && animate?
        on_loaded png
        play if @animated
      end

      def clear_image
        super
        reset_sample_cache # @animated / @frame_cache / @rendered_size / @sample
        set_content ""
      end

      # Streaming reuses frame index 0 with new content each tick; drop its cached
      # sample so `#render` re-samples the fresh bitmap instead of the stale one.
      protected def invalidate_frame(idx : Int32)
        @frame_cache.delete idx
        clear_frame_derived idx
      end

      # Hook: a subclass memoizes data derived from the *whole* composed frame
      # bitmap (a dither plane, a luminance threshold) in a `FrameMemo`, keyed by
      # animation frame index in lockstep with `@frame_cache`. Called at every
      # point `@frame_cache` is invalidated so the derived data can never outlive
      # the frame it was computed for. *idx* `nil` drops every frame's derived
      # data; a value drops only that frame's. No-op by default.
      protected def clear_frame_derived(idx : Int32? = nil)
      end

      # A directly-injected bitmap (`Media::Base#bitmap=`) changes content without
      # changing box size, so clear the per-size sample so the next render
      # re-samples it (live `Graph::Canvas` updates).
      protected def reset_sample_cache : Nil
        @animated = false
        @frame_cache.clear
        clear_frame_derived
        @rendered_size = nil
        @sample = nil
      end

      # Hook: called after a successful decode (e.g. `Media::Ansi` sizes the
      # widget to the image when no explicit size was given). Default no-op.
      protected def on_loaded(png : PNGGIF::PNG)
      end

      # Samples *img* into a bitmap for a *cols*×*rows* content box. *frame* is the
      # source frame to sample for animation, or `nil` for a still. Subclasses pick
      # the resolution (e.g. ×sub-grid) and cell aspect; see `Media::Fitting`.
      protected abstract def compose(img : PNGGIF::PNG, cols : Int32, rows : Int32,
                                     frame : PNGGIF::Bitmap?) : PNGGIF::Bitmap?

      # Paints the sampled *bmp* into the content cells `xi...xl`×`yi...yl`.
      protected abstract def draw_sample(bmp : PNGGIF::Bitmap, xi : Int32, xl : Int32, yi : Int32, yl : Int32)

      # Composites *char*/*attr* into *cell*, honouring the cell's aggregate
      # alpha *a*: `<= 0` leaves the cell untouched (fully transparent, e.g. a
      # letterbox margin), `>= 1` overwrites opaquely, in between blends both
      # colors (keeping the underlying glyph when this cell would only draw a
      # space). Shared primitive behind `Media::Ansi#paint_cell` and
      # `Media::Glyph`'s sub-cell painters.
      protected def blend_cell(cell, char : Char, attr : Int64, a : Float64) : Nil
        return if a <= 0.0
        if a < 1.0
          cell.attr = Colors.blend(attr, cell.attr, a)
          cell.char = char unless char == ' '
        else
          cell.attr = attr
          cell.char = char
        end
      end

      def render
        coords = _render
        return unless coords

        xi = coords.xi + ileft
        xl = coords.xl - iright
        yi = coords.yi + itop
        yl = coords.yl - ibottom

        # Resize support: (re)sample to the current content box when it changes.
        # For animation, only the *currently shown* frame is sampled (and
        # cached per size), so resizing doesn't regenerate every frame.
        if (img = source)
          cols = xl - xi
          rows = yl - yi
          if cols > 0 && rows > 0
            if @rendered_size != {cols, rows}
              @rendered_size = {cols, rows}
              @frame_cache.clear
              clear_frame_derived
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
