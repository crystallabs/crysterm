require "../image"
require "../box"

# `struct winsize` for reading the terminal's pixel dimensions via `TIOCGWINSZ`
# (the `ws_xpixel`/`ws_ypixel` that come back alongside rows/cols), so a graphics
# backend can derive the *real* cell pixel size instead of guessing. `ioctl` and
# `TIOCGWINSZ` are already bound on `LibC` by the term-screen shard.
lib LibCellSize
  struct Winsize
    ws_row : LibC::UShort
    ws_col : LibC::UShort
    ws_xpixel : LibC::UShort
    ws_ypixel : LibC::UShort
  end
end

module Crysterm
  class Widget
    # Shared base for *in-band terminal-graphics* image widgets — those that emit
    # an escape sequence the terminal itself renders into the VT window (sixel,
    # ReGIS), as opposed to:
    #
    # * `Image::Ansi`/`Image::Glyph`, which turn the image into character cells that
    #   Crysterm owns and diffs, or
    # * `Image::Overlay`, whose pixels are painted by an *external* helper.
    #
    # Like `Image::Overlay`, the pixels here are owned by the terminal, not by
    # Crysterm's cell buffer, so this class reuses the very same erase/redraw
    # lifecycle: the graphic is (re)painted *after* the screen flushes each
    # frame's cells (`Event::Rendered`), and the cells under the previous
    # position are force-re-emitted when the widget moves or hides
    # (`#invalidate_region`) so the terminal's own text rendering covers the
    # stale graphic. See `Image::Overlay` for the rationale behind this dance.
    #
    # Subclasses provide just two things: `#target_pixels` (the pixel resolution
    # to decode/draw at, given the widget's cell box) and `#encode` (turn a
    # decoded `PNGGIF::Bitmap` into the terminal-specific escape payload). This
    # base handles decoding, caching, cursor positioning and the lifecycle.
    abstract class Image::Graphics < Box
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

      # Play animated images (APNG / GIF) automatically.
      property? animate : Bool

      # Playback speed multiplier for animations (1.0 = native speed).
      property speed : Float64

      # The image decoded once at native resolution (resolution-independent
      # *source*); the sized render is derived from it for the current box and
      # cached, so resizing re-samples without re-parsing the file.
      @source : PNGGIF::PNG?
      @raw : Bytes?

      # Composited animation source frames (`{bitmap, delay_ms}`), built once
      # (capped, in a background fiber); each shown frame is sampled to the box.
      @src_frames : Array(Tuple(PNGGIF::Bitmap, Int32))?
      @anim_index = 0
      @playing = false
      @anim_checked = false

      # Per-frame payload cache for the *current* geometry, keyed on the
      # animation frame index — so a looping animation re-encodes each frame at
      # most once per size instead of on every loop. Cleared when the geometry
      # (size/origin/fit) changes; bounded by the frame count. `@payload`/
      # `@payload_key` track the payload currently selected, for the emit-skip.
      @frame_payloads = {} of Int32 => String
      @payload_geom : Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32)?
      @payload : String?
      @payload_key : Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)?
      # The key whose payload was last actually emitted (for backends that don't
      # need re-emitting every frame — see `#repaint_every_frame?`).
      @emitted_key : Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)?

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
        # 0 = auto-detect from the terminal (falls back to a typical xterm cell).
        @cell_pixel_width = 0,
        @cell_pixel_height = 0,
        @fit : Image::Fit = Image::Fit::Stretch,
        @animate : Bool = true,
        @speed : Float64 = 1.0,
        # Accepted-and-ignored Image::Overlay-specific options, so the
        # `Widget::Image` factory can forward one option bag to any backend.
        stretch = false,
        center = false,
        **box,
      )
        super **box

        # Resolve the cell pixel size: ask the terminal (TIOCGWINSZ) when the
        # caller didn't pin it, falling back to a typical monospace cell.
        if @cell_pixel_width <= 0 || @cell_pixel_height <= 0
          if cp = Image::Graphics.terminal_cell_pixels(screen?)
            @cell_pixel_width = cp[0] if @cell_pixel_width <= 0
            @cell_pixel_height = cp[1] if @cell_pixel_height <= 0
          end
        end
        @cell_pixel_width = 10 if @cell_pixel_width <= 0
        @cell_pixel_height = 20 if @cell_pixel_height <= 0

        # Mirror Image::Overlay: repaint after the *screen* finishes each render
        # (the cells are flushed by then, so the graphic lands on top), and use
        # PreRender to deal with the graphic left at our previous position.
        s = screen
        @listener_screen = s
        @ev_prerender = s.on(::Crysterm::Event::PreRender) { invalidate_old_position }
        @ev_rendered = s.on(::Crysterm::Event::Rendered) { redraw_image }

        on(::Crysterm::Event::Hide) { clear_graphic }
        on(::Crysterm::Event::Detach) { |e| clear_graphic e.object.as?(::Crysterm::Screen) }
        on(::Crysterm::Event::Show) { request_render }
        on(::Crysterm::Event::Destroy) { teardown }
      end

      # The terminal's real cell size in pixels, read from `TIOCGWINSZ`
      # (`ws_xpixel`/`ws_ypixel` ÷ columns/rows), or `nil` when the terminal
      # doesn't report pixel dimensions or the output isn't a tty.
      def self.terminal_cell_pixels(screen : ::Crysterm::Screen?) : Tuple(Int32, Int32)?
        s = screen || return nil
        tty = s.output
        return nil unless tty.is_a?(IO::FileDescriptor)
        ws = LibCellSize::Winsize.new
        return nil unless LibC.ioctl(tty.fd, LibC::TIOCGWINSZ, pointerof(ws)) == 0
        xp = ws.ws_xpixel.to_i
        yp = ws.ws_ypixel.to_i
        c = ws.ws_col.to_i
        r = ws.ws_row.to_i
        return nil unless xp > 0 && yp > 0 && c > 0 && r > 0
        {xp // c, yp // r}
      rescue
        nil
      end

      # Pixel resolution to decode and draw the image at, for a *cols* × *rows*
      # cell box. Subclasses may clamp to a device-specific maximum.
      abstract def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)

      # Pixel origin to draw at, given the content cell position (*xi*, *yi*). The
      # default maps cell coordinates through `cell_pixel_width/height` — correct
      # for graphics addressed in window pixels. Subclasses that address a
      # device-fixed logical space (e.g. ReGIS) override this.
      protected def origin_pixels(xi : Int32, yi : Int32) : Tuple(Int32, Int32)
        {xi * cell_pixel_width, yi * cell_pixel_height}
      end

      # Turns a decoded *bmp* (`pw` × `ph` pixels) into the terminal escape
      # sequence that draws it. *ox*/*oy* are the widget's pixel origin in the
      # terminal window — sixel ignores them (it draws at the cursor), but ReGIS
      # addresses absolute window pixels and needs them.
      abstract def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32) : String

      # Loads *file*, dropping the cached source and render so the next draw
      # re-decodes. Sizing itself is lazy (done at draw time for the current box).
      def load(file : String)
        stop
        @file = file
        @source = nil
        @raw = nil
        @src_frames = nil
        @anim_index = 0
        @anim_checked = false
        @frame_payloads.clear
        @payload_geom = nil
        @payload = nil
        @payload_key = nil
        @emitted_key = nil
        request_render
      end

      # Alias for `#load`, matching the other image backends' API.
      def set_image(file : String)
        load file
      end

      # Clears the loaded image, erasing its graphic from the screen.
      def clear_image
        stop
        clear_graphic
        @file = nil
        @source = nil
        @raw = nil
        @src_frames = nil
        @anim_index = 0
        @anim_checked = false
        @frame_payloads.clear
        @payload_geom = nil
        @payload = nil
        @payload_key = nil
        @emitted_key = nil
      end

      # The image decoded *once* at native resolution (via the shared, process-
      # wide `Image.decode` cache, so the same file shown by several widgets is
      # parsed only once). The sized render is then derived from this source for
      # whatever box is current, so a resize re-samples instead of re-parsing.
      protected def source : PNGGIF::PNG?
        if s = @source
          return s
        end
        file = @file || return nil
        @source = Image.decode file
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
            Widget::Image::Ansi.fetch file
          else
            File.read(file).to_slice
          end
      rescue
        nil
      end

      # Resamples the source into a *bw*×*bh* pixel bitmap fit per `#fit` (pixels
      # are square, so no aspect correction). This is what makes the backends
      # resize-aware: it re-derives from the cached source for the current box on
      # every size change. See `Image::Fitting`.
      protected def fit_bitmap(bw : Int32, bh : Int32) : PNGGIF::Bitmap?
        src = source || return nil
        if (frames = @src_frames) && (f = frames[@anim_index]?)
          Image::Fitting.compose src, f[0], bw, bh, @fit, 1.0
        else
          Image::Fitting.compose src, bw, bh, @fit, 1.0
        end
      end

      # Whether this backend must drive animation frame-by-frame itself. True for
      # backends the terminal draws statically (sixel/ReGIS/Kitty); iTerm2
      # overrides it to false because the terminal animates the GIF it's sent.
      protected def needs_frame_loop? : Bool
        true
      end

      # On the first paint, detect an animated source and start playback.
      private def ensure_animation
        return if @anim_checked
        @anim_checked = true
        return unless needs_frame_loop?
        src = source || return
        play if src.frames && animate?
      end

      # Index of the frame currently shown. The internal animation loop advances
      # it, but it can also be set directly (after `#pause`) to drive playback
      # from an external clock — e.g. to keep several images in lockstep.
      property anim_index : Int32

      # Whether the composited source frames have been built yet (the heavy
      # decode/composite happens in a background fiber on first `#play`). Once
      # true, the animation loop is actually advancing frames — useful to a
      # recorder that wants to start capturing only after playback is underway.
      def frames_ready? : Bool
        !@src_frames.nil?
      end

      # Starts animation playback. Source frames are composited once (capped, in a
      # background fiber so a big GIF doesn't block first paint); the loop then
      # advances the frame index and re-renders, so `#redraw_image` emits the
      # current frame (sampled to the current box) — which is what makes animated
      # graphics also resize.
      def play
        return if @playing
        src = source || return
        @playing = true
        if @src_frames
          spawn animate_loop
        else
          spawn do
            Fiber.yield # let the current frame paint before the heavy build
            sw, sh = Image::Fitting.source_size src
            frames = @src_frames = src.animation_cellmaps(sw, sh, 1.0)
            if frames && !frames.empty? && @playing
              animate_loop
            else
              @playing = false
            end
          end
        end
      end

      def pause
        @playing = false
      end

      def stop
        @playing = false
        @anim_index = 0
      end

      private def animate_loop
        frames = @src_frames
        return unless frames
        src = source
        num_plays = src ? src.num_plays : 0
        plays = 0
        while @playing
          request_render # fires Rendered -> redraw_image emits this frame

          delay = frames[@anim_index]?.try(&.[1]) || 100
          @anim_index += 1
          if @anim_index >= frames.size
            @anim_index = 0
            plays += 1
            break if num_plays > 0 && plays >= num_plays
          end

          ms = (delay / @speed).to_i
          ms = 1 if ms < 1
          sleep ms.milliseconds
        end
        @playing = false
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

      # Returns the payload for the given geometry + current frame, building it at
      # most once per frame per geometry. The per-frame cache is dropped whenever
      # the geometry (size/origin/fit) changes, so a looping animation at a stable
      # size encodes each frame only once, while a resize still re-encodes.
      private def payload_for(bw : Int32, bh : Int32, ox : Int32, oy : Int32,
                              cols : Int32, rows : Int32) : String?
        geom = {bw, bh, ox, oy, cols, rows, @fit.value}
        if @payload_geom != geom
          @payload_geom = geom
          @frame_payloads.clear
        end
        p = @frame_payloads[@anim_index]? || begin
          built = build_payload(bw, bh, ox, oy, cols, rows) || return nil
          @frame_payloads[@anim_index] = built
          built
        end
        @payload = p
        @payload_key = {bw, bh, ox, oy, cols, rows, @fit.value, @anim_index}
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
        ensure_animation
        pos = _get_coords(true) || return
        # Draw into the *content* area, inside any border/padding.
        xi = pos.xi + ileft
        yi = pos.yi + itop
        cols = (pos.xl - iright) - xi
        rows = (pos.yl - ibottom) - yi
        return if cols <= 0 || rows <= 0

        pw, ph = target_pixels(cols, rows)
        ox, oy = origin_pixels(xi, yi)
        payload = payload_for(pw, ph, ox, oy, cols, rows) || return

        # Sixel/ReGIS get overdrawn by the cells Crysterm flushes each frame, so
        # they must be re-emitted every render. A Kitty image is a separate layer
        # the cells don't touch, so it's emitted only when it actually changes
        # (new frame / move / resize) — avoiding flicker and needless re-transmits.
        unless repaint_every_frame?
          if @emitted_key == @payload_key
            @last_drawn = {xi, yi, cols, rows}
            return
          end
        end

        io = String::Builder.new
        io << "\e7"                                       # DECSC: save cursor
        io << "\e[" << (yi + 1) << ';' << (xi + 1) << 'H' # CUP to content top-left (1-based)
        io << payload
        io << "\e8" # DECRC: restore cursor
        s.tput._oprint io.to_s
        s.tput.flush

        @emitted_key = @payload_key
        @last_drawn = {xi, yi, cols, rows}
      end

      # Whether the graphic must be re-emitted on every screen render (true when
      # the terminal's cells overdraw it, e.g. sixel/ReGIS). Backends drawn on a
      # separate layer the cells don't touch (Kitty) override this to false and
      # are emitted only when the payload changes.
      protected def repaint_every_frame? : Bool
        true
      end

      # Before this frame's cells are composited: if we've moved since the last
      # paint, force Crysterm to re-emit the cells of the *previous* region so
      # the terminal's text rendering covers the graphic we left there. (Same
      # rationale as `Image::Overlay#invalidate_old_position`.)
      private def invalidate_old_position
        return unless @file && visible?
        last = @last_drawn || return
        pos = _get_coords(false) || return
        xi = pos.xi + ileft
        yi = pos.yi + itop
        rect = {xi, yi, (pos.xl - iright) - xi, (pos.yl - ibottom) - yi}
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
        @emitted_key = nil
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
        stop
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
