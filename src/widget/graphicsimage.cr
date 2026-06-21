require "./box"

module Crysterm
  class Widget
    # Shared base for *in-band terminal-graphics* image widgets — those that emit
    # an escape sequence the terminal itself renders into the VT window (sixel,
    # ReGIS), as opposed to:
    #
    # * `ANSIImage`/`GlyphImage`, which turn the image into character cells that
    #   Crysterm owns and diffs, or
    # * `OverlayImage`, whose pixels are painted by an *external* helper.
    #
    # Like `OverlayImage`, the pixels here are owned by the terminal, not by
    # Crysterm's cell buffer, so this class reuses the very same erase/redraw
    # lifecycle: the graphic is (re)painted *after* the screen flushes each
    # frame's cells (`Event::Rendered`), and the cells under the previous
    # position are force-re-emitted when the widget moves or hides
    # (`#invalidate_region`) so the terminal's own text rendering covers the
    # stale graphic. See `OverlayImage` for the rationale behind this dance.
    #
    # Subclasses provide just two things: `#target_pixels` (the pixel resolution
    # to decode/draw at, given the widget's cell box) and `#encode` (turn a
    # decoded `PNGGIF::Bitmap` into the terminal-specific escape payload). This
    # base handles decoding, caching, cursor positioning and the lifecycle.
    abstract class GraphicsImage < Box
      # Path (or URL) of the loaded image.
      property file : String?

      # Assumed terminal cell size in pixels, used to translate the widget's
      # cell box into a pixel resolution for the graphic. Defaults approximate a
      # typical monospace xterm; override to match your font, or rely on the
      # result roughly filling the box (graphics need not align to cell edges).
      property cell_pixel_width : Int32
      property cell_pixel_height : Int32

      # How the image is fit into the (possibly varying-size) box. Changing it
      # invalidates the cached render.
      property fit : Image::Fit

      # The image decoded once at native resolution (resolution-independent
      # *source*); the sized render is derived from it for the current box and
      # cached, so resizing re-samples without re-parsing the file.
      @source : PNGGIF::PNG?
      @raw : Bytes?

      # Cached encoded payload and the (pw, ph, ox, oy, cols, rows) it was built
      # for, so we don't re-encode on every frame (the lifecycle repaints every
      # render).
      @payload : String?
      @payload_key : Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32)?

      # Cell rectangle (`{xi, yi, w, h}`) the graphic was last painted at, used
      # to detect movement/resize so the old position can be cleared.
      @last_drawn : Tuple(Int32, Int32, Int32, Int32)?

      # Screen the render listeners were registered on (kept so they can be
      # removed on destroy even after the widget is detached).
      @listener_screen : ::Crysterm::Screen?
      @ev_prerender : ::Crysterm::Event::PreRender::Wrapper?
      @ev_rendered : ::Crysterm::Event::Rendered::Wrapper?

      def initialize(
        @file = nil,
        @cell_pixel_width = 10,
        @cell_pixel_height = 20,
        @fit : Image::Fit = Image::Fit::Stretch,
        # Accepted-and-ignored OverlayImage-specific options, so the
        # `Widget::Image` factory can forward one option bag to any backend.
        stretch = false,
        center = false,
        **box,
      )
        super **box

        # Mirror OverlayImage: repaint after the *screen* finishes each render
        # (the cells are flushed by then, so the graphic lands on top), and use
        # PreRender to deal with the graphic left at our previous position.
        s = screen
        @listener_screen = s
        @ev_prerender = s.on(::Crysterm::Event::PreRender) { invalidate_old_position }
        @ev_rendered = s.on(::Crysterm::Event::Rendered) { redraw_image }

        on(::Crysterm::Event::Hide) { clear_graphic }
        on(::Crysterm::Event::Detach) { |e| clear_graphic e.object.as?(::Crysterm::Screen) }
        on(::Crysterm::Event::Show) { screen?.try &.render }
        on(::Crysterm::Event::Destroy) { teardown }
      end

      # Pixel resolution to decode and draw the image at, for a *cols* × *rows*
      # cell box. Subclasses may clamp to a device-specific maximum.
      abstract def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)

      # Pixel origin to draw at, given the widget's cell position *pos*. The
      # default maps cell coordinates through `cell_pixel_width/height` — correct
      # for graphics addressed in window pixels. Subclasses that address a
      # device-fixed logical space (e.g. ReGIS) override this.
      protected def origin_pixels(pos) : Tuple(Int32, Int32)
        {pos.xi * cell_pixel_width, pos.yi * cell_pixel_height}
      end

      # Turns a decoded *bmp* (`pw` × `ph` pixels) into the terminal escape
      # sequence that draws it. *ox*/*oy* are the widget's pixel origin in the
      # terminal window — sixel ignores them (it draws at the cursor), but ReGIS
      # addresses absolute window pixels and needs them.
      abstract def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32) : String

      # Loads *file*, dropping the cached source and render so the next draw
      # re-decodes. Sizing itself is lazy (done at draw time for the current box).
      def load(file : String)
        @file = file
        @source = nil
        @raw = nil
        @payload = nil
        @payload_key = nil
        screen?.try &.render
      end

      # Alias for `#load`, matching the other image backends' API.
      def set_image(file : String)
        load file
      end

      # Clears the loaded image, erasing its graphic from the screen.
      def clear_image
        clear_graphic
        @file = nil
        @source = nil
        @raw = nil
        @payload = nil
        @payload_key = nil
      end

      # Decodes the image *once* at native resolution and caches it. The sized
      # render is then derived from this source for whatever box is current, so a
      # resize re-samples instead of re-parsing the file.
      protected def source : PNGGIF::PNG?
        if s = @source
          return s
        end
        file = @file || return nil
        data : String | Bytes = file
        data = Widget::ANSIImage.fetch(file) if file =~ /^https?:/
        @source = PNGGIF::PNG.new(data)
      rescue
        nil
      end

      # Returns the original (undecoded) image bytes, cached. Used by backends
      # that transmit the encoded file as-is (e.g. iTerm2).
      protected def raw_bytes : Bytes?
        if b = @raw
          return b
        end
        file = @file || return nil
        @raw =
          if file =~ /^https?:/
            Widget::ANSIImage.fetch file
          else
            File.read(file).to_slice
          end
      rescue
        nil
      end

      # Resamples the source into a *bw*×*bh* pixel bitmap fit per `#fit` (pixels
      # are square, so no aspect correction). This is what makes the backends
      # resize-aware: it re-derives from the cached source for the current box on
      # every size change. See `ImageFitting`.
      protected def fit_bitmap(bw : Int32, bh : Int32) : PNGGIF::Bitmap?
        src = source || return nil
        ImageFitting.compose src, bw, bh, @fit, 1.0
      end

      # Builds the full escape payload for a *bw*×*bh* box. The default path
      # resamples the source (fit into the box) and hands the bitmap to
      # `#encode`. Backends that transmit the original file bytes (iTerm2)
      # override this and use `#raw_bytes` + the cell box instead.
      protected def build_payload(bw : Int32, bh : Int32, ox : Int32, oy : Int32,
                                  cols : Int32, rows : Int32) : String?
        bmp = fit_bitmap(bw, bh) || return nil
        real_h = bmp.size
        real_w = bmp[0]?.try(&.size) || 0
        return nil if real_w == 0 || real_h == 0
        encode(bmp, real_w, real_h, ox, oy)
      end

      # Returns the payload for the given geometry, building it once and caching
      # until any of the geometry, the fit, or the image changes.
      private def payload_for(bw : Int32, bh : Int32, ox : Int32, oy : Int32,
                              cols : Int32, rows : Int32) : String?
        key = {bw, bh, ox, oy, cols, rows, @fit.value}
        return @payload if @payload_key == key
        p = build_payload(bw, bh, ox, oy, cols, rows) || return nil
        @payload = p
        @payload_key = key
        p
      end

      # (Re)paints the graphic at the widget's current position. Runs after every
      # screen render so it stays on top of the freshly-drawn cells; skips while
      # hidden or detached. Wraps the emit in DECSC/DECRC so the terminal cursor
      # (and thus Crysterm's positioning on the next frame) is left untouched.
      private def redraw_image
        return unless visible?
        s = screen? || return
        return unless @file
        pos = _get_coords(true) || return
        cols = pos.xl - pos.xi
        rows = pos.yl - pos.yi
        return if cols <= 0 || rows <= 0

        pw, ph = target_pixels(cols, rows)
        ox, oy = origin_pixels(pos)
        payload = payload_for(pw, ph, ox, oy, cols, rows) || return

        io = String::Builder.new
        io << "\e7"                                               # DECSC: save cursor
        io << "\e[" << (pos.yi + 1) << ';' << (pos.xi + 1) << 'H' # CUP to box top-left (1-based)
        io << payload
        io << "\e8" # DECRC: restore cursor
        s.tput._oprint io.to_s
        s.tput.flush

        @last_drawn = {pos.xi, pos.yi, cols, rows}
      end

      # Before this frame's cells are composited: if we've moved since the last
      # paint, force Crysterm to re-emit the cells of the *previous* region so
      # the terminal's text rendering covers the graphic we left there. (Same
      # rationale as `OverlayImage#invalidate_old_position`.)
      private def invalidate_old_position
        return unless @file && visible?
        last = @last_drawn || return
        pos = _get_coords(false) || return
        rect = {pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi}
        return if last == rect
        screen.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
      end

      # Erases the graphic at its last position by forcing those cells to be
      # re-emitted, then forgets the position.
      private def clear_graphic(on_screen : ::Crysterm::Screen? = nil)
        last = @last_drawn || return
        s = on_screen || screen? || return
        graphic_cleared s
        s.invalidate_region(last[0], last[0] + last[2], last[1], last[1] + last[3])
        @last_drawn = nil
        s.render
      end

      # Hook for backends whose pixels are NOT erased by re-emitting the cells
      # underneath (re-emitted text covers sixel/ReGIS, but not e.g. a Kitty
      # image, which is a separate layer that must be explicitly deleted).
      # Called from `#clear_graphic` before the cells are invalidated. No-op by
      # default.
      protected def graphic_cleared(s : ::Crysterm::Screen)
      end

      private def teardown
        s = @listener_screen || return
        @ev_prerender.try { |w| s.off ::Crysterm::Event::PreRender, w }
        @ev_rendered.try { |w| s.off ::Crysterm::Event::Rendered, w }
        @ev_prerender = nil
        @ev_rendered = nil
        @listener_screen = nil
      end
    end
  end
end
