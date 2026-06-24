require "./base"

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
    # * `Media::Ansi`/`Media::Glyph`, which turn the image into character cells that
    #   Crysterm owns and diffs, or
    # * `Media::Overlay`, whose pixels are painted by an *external* helper.
    #
    # Like `Media::Overlay`, the pixels here are owned by the terminal, not by
    # Crysterm's cell buffer, so this class reuses the very same erase/redraw
    # lifecycle: the graphic is (re)painted *after* the screen flushes each
    # frame's cells (`Event::Rendered`), and the cells under the previous
    # position are force-re-emitted when the widget moves or hides
    # (`#invalidate_region`) so the terminal's own text rendering covers the
    # stale graphic. See `Media::Overlay` for the rationale behind this dance.
    #
    # Subclasses provide just two things: `#target_pixels` (the pixel resolution
    # to decode/draw at, given the widget's cell box) and `#encode` (turn a
    # decoded `PNGGIF::Bitmap` into the terminal-specific escape payload). This
    # base handles decoding, caching, cursor positioning and the lifecycle.
    # Abstract base for the **in-band terminal-graphics** backends — those that
    # emit an escape sequence the terminal itself renders as pixels (`Media::Sixel`,
    # `Media::Regis`, `Media::Kitty`, `Media::Iterm`). The image source and the
    # render-driven animation framework come from `Media::Base`; this layer adds
    # the pixel-resolution/encoding machinery and the "screen owns the pixels"
    # erase-on-move lifecycle the cell grid doesn't manage.
    abstract class Media::Graphics < Media::Base
      # Assumed terminal cell size in pixels, used to translate the widget's
      # cell box into a pixel resolution for the graphic. Defaults approximate a
      # typical monospace xterm; override to match your font, or rely on the
      # result roughly filling the box (graphics need not align to cell edges).
      property cell_pixel_width : Int32
      property cell_pixel_height : Int32

      # Native resolution is the cell box times the (probed) cell pixel size, so a
      # `Graph::Canvas` bitmap is drawn at the terminal's true pixel resolution.
      def native_resolution(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        {cols * @cell_pixel_width, rows * @cell_pixel_height}
      end

      # True terminal pixels are square.
      def native_pixel_aspect : Float64
        1.0
      end

      # Present each frame's emit atomically by wrapping it in a synchronized
      # output (DEC private mode 2026) update, so the terminal never shows a
      # partial/torn frame or a mid-update blank. `Media::Kitty` additionally
      # double-buffers via alternating image ids. Terminals that don't understand
      # 2026 ignore the wrapper, so this is always safe to leave on.
      property? double_buffer : Bool = true

      # Original (undecoded) bytes cache, for backends that transmit the file
      # as-is (iTerm2). The decoded `@source`/frames live in `Media::Base`.
      @raw : Bytes?

      # Set once the first paint has checked whether the source is animated.
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
        @fit : Media::Fit = Media::Fit::Stretch,
        animate : Bool | Timer = true,
        @speed : Float64 = 1.0,
        @double_buffer : Bool = Crysterm::Config.media_double_buffer,
        **box,
      )
        super **box
        setup_animate animate

        # Resolve the cell pixel size: ask the terminal (TIOCGWINSZ) when the
        # caller didn't pin it, falling back to a typical monospace cell.
        if @cell_pixel_width <= 0 || @cell_pixel_height <= 0
          if cp = Media::Graphics.terminal_cell_pixels(screen?)
            @cell_pixel_width = cp[0] if @cell_pixel_width <= 0
            @cell_pixel_height = cp[1] if @cell_pixel_height <= 0
          end
        end
        @cell_pixel_width = 10 if @cell_pixel_width <= 0
        @cell_pixel_height = 20 if @cell_pixel_height <= 0

        # Mirror Media::Overlay: repaint after the *screen* finishes each render
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
      # addresses absolute window pixels and needs them. *cols*/*rows* are the
      # target cell box; a backend that lets the terminal scale the image (Kitty's
      # `c=`/`r=`) uses them so the transmitted pixel size can be smaller than the
      # box. Pixel-exact backends (sixel/ReGIS) ignore them.
      abstract def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                          cols : Int32, rows : Int32) : String

      # Native pixel resolution of the current source — the animation frame being
      # shown (`@src_frames`) or, for a still, the decoded canvas. Used by a
      # scaling backend to avoid transmitting more pixels than the source has
      # (which for video would re-upload a full-window frame every tick).
      protected def source_resolution : Tuple(Int32, Int32)?
        if (frames = @src_frames) && (f = frames[@anim_index]?)
          bmp = f[0]
          h = bmp.size
          w = h > 0 ? bmp[0].size : 0
          return {w, h} if w > 0 && h > 0
        elsif (png = source)
          cw = png.canvas_width
          ch = png.canvas_height
          return {cw, ch} if cw > 0 && ch > 0
        end
        nil
      end

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

      # Clears the loaded image, erasing its graphic from the screen.
      def clear_image
        clear_graphic
        super # stop + drop file/source/frames
        @raw = nil
        @anim_checked = false
        @frame_payloads.clear
        @payload_geom = nil
        @payload = nil
        @payload_key = nil
        @emitted_key = nil
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
            Widget::Media::Ansi.fetch file
          else
            File.read(file).to_slice
          end
      rescue
        nil
      end

      # Resamples the source into a *bw*×*bh* pixel bitmap fit per `#fit` (pixels
      # are square, so no aspect correction). This is what makes the backends
      # resize-aware: it re-derives from the cached source for the current box on
      # every size change. See `Media::Fitting`.
      protected def fit_bitmap(bw : Int32, bh : Int32) : PNGGIF::Bitmap?
        src = source || return nil
        if (frames = @src_frames) && (f = frames[@anim_index]?)
          Media::Fitting.compose src, f[0], bw, bh, @fit, 1.0
        else
          Media::Fitting.compose src, bw, bh, @fit, 1.0
        end
      end

      # Whether this backend must drive animation frame-by-frame itself. True for
      # backends the terminal draws statically (sixel/ReGIS/Kitty); iTerm2
      # overrides it to false because the terminal animates the GIF it's sent.
      protected def needs_frame_loop? : Bool
        true
      end

      # On the first paint, detect an animated source and start playback. (The
      # `#play`/`#animate_loop` framework itself lives in `Media::Base`.)
      private def ensure_animation
        return if @anim_checked
        @anim_checked = true
        return unless needs_frame_loop?
        src = source || return
        play if src.frames && animate?
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
        encode(bmp, real_w, real_h, ox, oy, cols, rows)
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

      # Streaming reuses frame index 0 with new content each tick. Drop its cached
      # payload so it re-encodes, and clear `@emitted_key` so the change-skip in
      # `#redraw_image` (used by Kitty, `repaint_every_frame? == false`) doesn't
      # treat the new frame as the already-emitted one and freeze on frame 0.
      protected def invalidate_frame(idx : Int32)
        @frame_payloads.delete idx
        @emitted_key = nil
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
        io << "\e[?2026h" if double_buffer?               # BSU: begin synchronized update
        io << "\e7"                                       # DECSC: save cursor
        io << "\e[" << (yi + 1) << ';' << (xi + 1) << 'H' # CUP to content top-left (1-based)
        io << payload
        io << "\e8"                         # DECRC: restore cursor
        io << "\e[?2026l" if double_buffer? # ESU: end synchronized update — present atomically
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
      # rationale as `Media::Overlay#invalidate_old_position`.)
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
