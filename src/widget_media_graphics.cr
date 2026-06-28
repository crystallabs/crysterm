require "./widget_media_base"
require "./widget_media_screen_overlay"

# `struct winsize` (for the `ws_xpixel`/`ws_ypixel` that come back from
# `TIOCGWINSZ` alongside rows/cols, so a graphics backend can derive the *real*
# cell pixel size instead of guessing), `ioctl` and `TIOCGWINSZ` are all already
# bound on `LibC` by the term-screen shard — reused here as `LibC::Winsize`.

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
      include Media::ScreenOverlay

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

      # `@last_drawn` and the listener-wrapper ivars (`@listener_screen`,
      # `@ev_prerender`, `@ev_rendered`) come from `Media::ScreenOverlay`.

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

        # Resolve the cell pixel size: when the caller didn't pin it, reuse what
        # the Screen already detected at startup (one shared TIOCGWINSZ plus an
        # XTWINOPS fallback this path doesn't do itself), then fall back to a
        # typical monospace cell when the terminal reported nothing.
        if s = screen?
          @cell_pixel_width = s.cell_pixel_width if @cell_pixel_width <= 0
          @cell_pixel_height = s.cell_pixel_height if @cell_pixel_height <= 0
        end
        @cell_pixel_width = 10 if @cell_pixel_width <= 0
        @cell_pixel_height = 20 if @cell_pixel_height <= 0

        # Mirror Media::Overlay: repaint after the *screen* finishes each render
        # (the cells are flushed by then, so the graphic lands on top), and use
        # PreRender to deal with the graphic left at our previous position.
        register_overlay_listeners screen
      end

      # The terminal's real cell size in pixels, read from `TIOCGWINSZ`
      # (`ws_xpixel`/`ws_ypixel` ÷ columns/rows), or `nil` when the terminal
      # doesn't report pixel dimensions or the output isn't a tty.
      def self.terminal_cell_pixels(screen : ::Crysterm::Screen?) : Tuple(Int32, Int32)?
        s = screen || return nil
        tty = s.output
        return nil unless tty.is_a?(IO::FileDescriptor)
        ws = LibC::Winsize.new
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
        reset_payload_cache
        request_render
      end

      # Clears the loaded image, erasing its graphic from the screen.
      def clear_image
        clear_overlay
        super # stop + drop file/source/frames
        @raw = nil
        reset_payload_cache
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

      # In-band terminal graphics ARE visible to the terminal, so they are
      # composited into captures (`Crysterm::Capture`).
      def capture_pixels? : Bool
        true
      end

      # Current frame resampled to the widget's content cell-box × font cell size,
      # plus its content top-left cell origin — composited by the capture
      # renderer at the same place the terminal draws the graphic. Mirrors the
      # geometry of `#redraw_image`. `nil` while hidden or with no image.
      def capture_layer(font_w : Int32, font_h : Int32) : Tuple(PNGGIF::Bitmap, Int32, Int32)?
        return nil unless visible?
        return nil unless has_image?
        pos = _get_coords(true) || return nil
        xi, yi, cols, rows = overlay_rect pos
        return nil if cols <= 0 || rows <= 0
        bmp = fit_bitmap(cols * font_w, rows * font_h) || return nil
        {bmp, xi, yi}
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

      # A directly-injected bitmap (`Media::Base#bitmap=`) replaces the source
      # content without changing the box geometry, so `#payload_for`'s
      # geometry-keyed cache would otherwise keep serving the *previous* frame's
      # encoded payload (and the `#redraw_image` emit-skip would treat it as
      # already on screen for separate-layer backends like Kitty), freezing the
      # graphic on the stale image. Drop the per-frame payload cache and the
      # emit-tracking keys so the next render re-encodes the fresh bitmap and
      # re-emits it. Mirrors `Media::Cells#reset_sample_cache`.
      protected def reset_sample_cache : Nil
        reset_payload_cache
      end

      # Drops the per-frame payload cache and all emit-tracking keys, and forces
      # the next paint to re-detect whether the source animates. Shared by
      # `#load`, `#clear_image` and `#reset_sample_cache` — every entry point that
      # invalidates the encoded-frame state.
      private def reset_payload_cache : Nil
        @anim_checked = false
        @frame_payloads.clear
        @payload_geom = nil
        @payload = nil
        @payload_key = nil
        @emitted_key = nil
      end

      # (Re)paints the graphic at the widget's current position. Runs after every
      # screen render so it stays on top of the freshly-drawn cells; skips while
      # hidden or detached. Wraps the emit in DECSC/DECRC so the terminal cursor
      # (and thus Crysterm's positioning on the next frame) is left untouched.
      private def redraw_image
        return unless visible?
        # `visible?` only consults THIS widget's own flag. Unlike the cell-render
        # pass (which never paints a hidden subtree, so its descendants are
        # naturally skipped), this overlay runs as a standalone `Rendered`
        # listener, so it must also bail when an ANCESTOR is hidden: the widget is
        # then off-screen, the hidden ancestor has no rendered position, and
        # resolving coords against it (`_get_coords(true)` →
        # `last_rendered_position`) would raise instead of returning nil — crashing
        # the render-loop fiber. Walk the parent chain and skip if any link is
        # hidden, mirroring the tree-aware visibility `Capture` uses.
        anc = parent
        while anc
          return unless anc.visible?
          anc = anc.parent
        end
        s = screen? || return
        return unless has_image?
        ensure_animation
        pos = _get_coords(true) || return
        # Draw into the *content* area, inside any border/padding (`#overlay_rect`).
        xi, yi, cols, rows = overlay_rect pos
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

      # Draw into the *content* area, inside any border/padding (the in-band
      # erase/track rectangle the shared `Media::ScreenOverlay` lifecycle uses).
      protected def overlay_rect(pos) : Tuple(Int32, Int32, Int32, Int32)
        xi = pos.xi + ileft
        yi = pos.yi + itop
        {xi, yi, (pos.xl - iright) - xi, (pos.yl - ibottom) - yi}
      end

      # The graphic is only on screen once an image is present — either a loaded
      # file or a directly-injected in-memory source (`Media::Base#bitmap=`, the
      # `Graph::Canvas` path), which leaves `@file` nil but sets `@source`.
      protected def overlay_visible? : Bool
        has_image?
      end

      # Whether this backend currently has something to draw: a loaded file path
      # or an injected in-memory source. The whole-frame paint/erase/capture
      # lifecycle keys on this rather than on `@file` alone, so a bitmap-fed
      # graphic (no file) still renders.
      protected def has_image? : Bool
        !(@file.nil? && @source.nil?)
      end

      # On erase, give a separate-layer backend (Kitty) the chance to delete its
      # image, and drop the emit-skip key so a re-show re-emits.
      protected def overlay_cleared(s : ::Crysterm::Screen)
        graphic_cleared s
        @emitted_key = nil
      end

      # Hook for backends whose pixels are NOT erased by re-emitting the cells
      # underneath (re-emitted text covers sixel/ReGIS, but not e.g. a Kitty
      # image, which is a separate layer that must be explicitly deleted).
      # Called from `#overlay_cleared` before the cells are invalidated. No-op by
      # default.
      protected def graphic_cleared(s : ::Crysterm::Screen)
      end

      private def teardown
        stop
        teardown_overlay_listeners
      end
    end
  end
end
