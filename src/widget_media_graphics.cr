require "./widget_media_base"
require "./widget_media_screen_overlay"

# `struct winsize` (for `ws_xpixel`/`ws_ypixel` from `TIOCGWINSZ`, letting a
# graphics backend derive the real cell pixel size instead of guessing),
# `ioctl` and `TIOCGWINSZ` are already bound on `LibC` by the term-window
# shard — reused here as `LibC::Winsize`.

module Crysterm
  class Widget
    # Abstract base for the **in-band terminal-graphics** backends — those that
    # emit an escape sequence the terminal itself renders as pixels
    # (`Media::Sixel`, `Media::Regis`, `Media::Kitty`, `Media::Iterm`), as
    # opposed to:
    #
    # * `Media::Ansi`/`Media::Glyph`, which turn the image into character cells
    #   Crysterm owns and diffs, or
    # * `Media::Overlay`, whose pixels are painted by an *external* helper.
    #
    # Like `Media::Overlay`, the pixels here are owned by the terminal, not
    # Crysterm's cell buffer, so this class reuses the same erase/redraw
    # lifecycle: the graphic is (re)painted *after* the window flushes each
    # frame's cells (`Event::Rendered`), and the cells under the previous
    # position are force-re-emitted when the widget moves or hides
    # (`#invalidate_region`) so the terminal's own text rendering covers the
    # stale graphic. See `Media::Overlay` for the rationale.
    #
    # The image source and render-driven animation framework come from
    # `Media::Base`; subclasses provide `#target_pixels` (pixel resolution to
    # decode/draw at, given the widget's cell box) and `#encode` (decoded
    # `PNGGIF::Bitmap` -> terminal-specific escape payload). This base handles
    # decoding, caching, cursor positioning and the lifecycle.
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
      # partial/torn frame. `Media::Kitty` additionally double-buffers via
      # alternating image ids. Terminals that don't understand 2026 ignore the
      # wrapper, so this is always safe to leave on.
      getter? double_buffer : Bool = true

      # Runtime setter: the double-buffer flag changes the *shape* of the encoded
      # per-frame payload (`Media::Kitty#encode` bakes in the place-then-delete
      # swap suffix), and that payload is memoized per geometry — so a plain
      # assignment would keep serving cached bytes built under the old mode
      # (emitting a literal `{o}` placeholder in the single-buffer path, and
      # never issuing the swap's delete). Drop the payload cache so subsequent
      # frames re-encode under the new mode; the `#on_double_buffer_changed` hook
      # lets a backend clean up terminal state the cache drop can't reach (a
      # still-placed alternate buffer).
      def double_buffer=(v : Bool) : Bool
        unless v == @double_buffer
          @double_buffer = v
          reset_payload_cache
          on_double_buffer_changed v
        end
        v
      end

      # Hook run after `double_buffer` actually changes, for a backend that must
      # emit terminal state the cache drop can't (e.g. `Media::Kitty` deleting
      # the now-unused second buffer left placed on screen). No-op by default.
      protected def on_double_buffer_changed(v : Bool)
      end

      # Original (undecoded) bytes cache, for backends that transmit the file
      # as-is (iTerm2). The decoded `@source`/frames live in `Media::Base`.
      @raw : Bytes?

      # Latches a failed `#raw_bytes` read so a broken source (unreachable URL
      # → curl/wget, or a deleted/unreadable local file → File.read) isn't
      # re-attempted on every rendered frame. Mirrors `Media::Base`'s decode
      # failure latch; cleared by `#load`/`#clear_image` so a corrected source
      # is retried.
      @raw_failed = false

      # Set once the first paint has checked whether the source is animated.
      @anim_checked = false

      # Per-frame payload cache for the *current* geometry, keyed by animation
      # frame index, so a looping animation re-encodes each frame at most once
      # per size. Cleared when the geometry (size/origin/fit) changes; bounded
      # by the frame count. `@payload`/`@payload_key` track the payload
      # currently selected, for the emit-skip.
      @frame_payloads = {} of Int32 => String
      @payload_geom : Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32)?
      @payload : String?
      @payload_key : Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)?
      # The key whose payload was last actually emitted (for backends that don't
      # need re-emitting every frame — see `#repaint_every_frame?`).
      @emitted_key : Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)?

      # `@last_drawn` and the listener-wrapper ivars (`@listener_screen`,
      # `@ev_prerender`, `@ev_rendered`) come from `Media::ScreenOverlay`.

      # Scratch `RenderedGeometry` reused by `#content_rect` (called by `#redraw_image`
      # every `Rendered`, and by `#capture_layer`) to avoid a heap `RenderedGeometry`
      # allocation per call (`coords` with no `into:` allocates fresh —
      # see widget_position.cr:638-641). Each call fully unpacks the result
      # into a plain `Tuple` before returning, so reusing one buffer across
      # calls (even nested ones within the same render pass) is safe.
      @content_lpos : RenderedGeometry = RenderedGeometry.new

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

        # Remember which dimensions the caller left to auto-detect (0), before
        # the fallback below overwrites them — so a detached construction can
        # still adopt the window's real cell size once attached.
        @cell_pixel_auto_w = @cell_pixel_width <= 0
        @cell_pixel_auto_h = @cell_pixel_height <= 0

        # Resolve the cell pixel size: when the caller didn't pin it, reuse what
        # the Window already detected at startup (shared TIOCGWINSZ / XTWINOPS
        # probe). Fall back to a typical monospace cell if there's no window yet
        # (detached construction) or it didn't report pixel dimensions.
        window?.try { |s| resolve_cell_pixels s }
        @cell_pixel_width = 10 if @cell_pixel_width <= 0
        @cell_pixel_height = 20 if @cell_pixel_height <= 0

        # Mirror Media::Overlay: repaint after the window finishes each render
        # (cells flushed by then, so the graphic lands on top), and use
        # PreRender for the graphic left at the previous position. When built
        # detached, this defers registration (and a real cell-size re-resolve)
        # until the widget is attached to a window.
        register_overlay_listeners_deferred
      end

      # Whether the corresponding cell pixel dimension was left to auto-detect.
      @cell_pixel_auto_w = false
      @cell_pixel_auto_h = false

      # Fills in the auto-detect (0) cell pixel dimensions from what the window
      # detected at startup, keeping any dimension the caller pinned. Skips a
      # dimension the window can't report (leaves the current value, e.g. the
      # 10×20 fallback).
      protected def resolve_cell_pixels(s : ::Crysterm::Window) : Nil
        @cell_pixel_width = s.cell_pixel_width if @cell_pixel_auto_w && s.cell_pixel_width > 0
        @cell_pixel_height = s.cell_pixel_height if @cell_pixel_auto_h && s.cell_pixel_height > 0
      end

      # On (deferred) attach, re-resolve the real cell size from the window that
      # now knows it, then register the overlay listeners.
      protected def on_overlay_window(s : ::Crysterm::Window)
        resolve_cell_pixels s
        register_overlay_listeners s
      end

      # The terminal's real cell size in pixels, read from `TIOCGWINSZ`
      # (`ws_xpixel`/`ws_ypixel` ÷ columns/rows), or `nil` when the terminal
      # doesn't report pixel dimensions or the output isn't a tty.
      def self.terminal_cell_pixels(window : ::Crysterm::Screen?) : Tuple(Int32, Int32)?
        s = window || return nil
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
      # terminal window — sixel ignores them (draws at the cursor), ReGIS needs
      # them (addresses absolute window pixels). *cols*/*rows* are the target
      # cell box; a backend that lets the terminal scale the image (Kitty's
      # `c=`/`r=`) uses them so the transmitted pixel size can be smaller than
      # the box. Pixel-exact backends (sixel/ReGIS) ignore them.
      abstract def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                          cols : Int32, rows : Int32) : String

      # Native pixel resolution of the current source — the animation frame
      # being shown (`@src_frames`) or, for a still, the decoded canvas. Used by
      # a scaling backend to avoid transmitting more pixels than the source has
      # (for video, that would re-upload a full-window frame every tick).
      protected def source_resolution : Tuple(Int32, Int32)?
        if (frames = @src_frames) && (f = frames[@anim_index]?)
          bmp = f[0]
          w, h = Media.dims(bmp)
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
        reset_source_state file
        @raw = nil
        @raw_failed = false
        @anim_checked = false
        reset_payload_cache
        request_render
      end

      # Clears the loaded image, erasing its graphic from the window.
      def clear_image
        clear_overlay
        super # stop + drop file/source/frames
        @raw = nil
        @raw_failed = false
        @anim_checked = false
        reset_payload_cache
      end

      # Returns the original (undecoded) image bytes, cached. Used by backends
      # that transmit the encoded file as-is (e.g. iTerm2).
      protected def raw_bytes : Bytes?
        if b = @raw
          return b
        end
        return nil if @raw_failed
        file = @file || return nil
        @raw =
          if file =~ /^https?:/
            Widget::Media::Ansi.fetch file
          else
            File.read(file).to_slice
          end
      rescue
        @raw_failed = true
        nil
      end

      # In-band terminal graphics are visible to the terminal, so they are
      # composited into captures (`Crysterm::Capture`).
      def capture_pixels? : Bool
        true
      end

      # The non-empty content cell-rectangle `{xi, yi, cols, rows}` this widget
      # currently occupies — its rendered coords inset by border/padding
      # (`#overlay_rect`) — or `nil` when it has no rendered position or is
      # zero-sized. The shared geometry behind the paint path (`#redraw_image`)
      # and the capture path (`#capture_layer`).
      private def content_rect : Tuple(Int32, Int32, Int32, Int32)?
        pos = coords(true, into: @content_lpos) || return nil
        xi, yi, cols, rows = overlay_rect pos
        return nil if cols <= 0 || rows <= 0
        # A partially-offscreen widget (negative origin) is not drawable: the
        # CUP `#redraw_image` emits would be clamped (`\e[0;…H` — one row off,
        # unclipped) or outright malformed (`\e[-1;…H`, splatting the image at
        # the current cursor), and `@last_drawn` would record the negative rect
        # so the erase pass targeted the wrong cells. Treat it like a hidden
        # widget (nil → skip paint / clear), matching the cell backends which
        # get clipped by the normal render pass.
        return nil if xi < 0 || yi < 0
        {xi, yi, cols, rows}
      end

      # Current frame resampled to the widget's content cell-box × font cell
      # size, plus its content top-left cell origin — composited by the capture
      # renderer at the same place the terminal draws the graphic. Mirrors
      # `#redraw_image`'s geometry. `nil` while hidden or with no image.
      def capture_layer(font_w : Int32, font_h : Int32) : Tuple(PNGGIF::Bitmap, Int32, Int32)?
        return nil unless visible?
        return nil unless has_image?
        xi, yi, cols, rows = content_rect || return nil
        bmp = fit_bitmap(cols * font_w, rows * font_h) || return nil
        {bmp, xi, yi}
      end

      # Resamples the source into a *bw*×*bh* pixel bitmap fit per `#fit` (pixels
      # are square, so no aspect correction). Re-derives from the cached source
      # on every size change, making the backends resize-aware. See
      # `Media::Fitting`. `pixel_box` marks the box as true device pixels, so
      # `Fit::None` draws the source at its native pixel size instead of a
      # cell footprint (which would halve its height by the cell aspect ratio).
      protected def fit_bitmap(bw : Int32, bh : Int32, transient : Bool = false) : PNGGIF::Bitmap?
        src = source || return nil
        frame = @src_frames.try(&.[@anim_index]?).try &.[0]
        # Reuse fast path (opt-in via `media.reuse_buffers`): the graphics backends
        # feed the fit bitmap straight into `#encode` and discard it — unlike
        # `Media::Cells`, which caches its sample — so when a *transient* caller
        # (`#build_payload`) asks and the source already matches the target box
        # exactly, the resample in `Media::Fitting.compose` is a pure identity copy.
        # That is the common `Graph::Canvas` case: it paints at
        # `native_resolution == the pixel box`, so an animated donut/chart otherwise
        # allocates a fresh `bw*bh` bitmap every frame just to copy pixels it already
        # has. Hand the source pixels straight to `#encode` instead. `#capture_layer`
        # never opts in — it hands the bitmap to an external holder (the capture
        # compositor) that must own a copy stable across the next repaint.
        if transient && Config.media_reuse_buffers
          cand = frame || src.bmp
          sw, sh = Media.dims(cand)
          return cand if sw == bw && sh == bh
        end
        Media::Fitting.compose src, frame, bw, bh, @fit, 1.0, pixel_box: true
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
        # First-paint animation probe is a load-time entry point: it may open
        # the live video decoder (guarded by `@anim_checked`, so a post-`stop`
        # render never re-opens it — only `#load`/`#clear_image` re-arm it).
        src = source(open_stream: true) || return
        play if src.frames && animate?
      end

      # Builds the full escape payload for a *bw*×*bh* box: resamples the source
      # (fit into the box) and hands the bitmap to `#encode`. Backends that
      # transmit the original file bytes (iTerm2) override this and use
      # `#raw_bytes` + the cell box instead.
      protected def build_payload(bw : Int32, bh : Int32, ox : Int32, oy : Int32,
                                  cols : Int32, rows : Int32) : String?
        bmp = fit_bitmap(bw, bh, transient: true) || return nil
        real_w, real_h = Media.dims(bmp)
        return nil if real_w == 0 || real_h == 0
        encode(bmp, real_w, real_h, ox, oy, cols, rows)
      end

      # Returns the payload for the given geometry + current frame, building it
      # at most once per frame per geometry. The per-frame cache is dropped
      # whenever the geometry (size/origin/fit) changes, so a resize still
      # re-encodes.
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

      # Streaming reuses frame index 0 with new content each tick. Drop its
      # cached payload so it re-encodes, and clear `@emitted_key` so the
      # change-skip in `#redraw_image` (Kitty, `repaint_every_frame? == false`)
      # doesn't treat the new frame as already-emitted and freeze on frame 0.
      protected def invalidate_frame(idx : Int32)
        @frame_payloads.delete idx
        @emitted_key = nil
      end

      # A directly-injected bitmap (`Media::Base#bitmap=`) replaces the source
      # without changing the box geometry, so `#payload_for`'s geometry-keyed
      # cache would otherwise keep serving the *previous* frame's encoded
      # payload — freezing the graphic on the stale image (the `#redraw_image`
      # emit-skip would treat it as already on window for separate-layer
      # backends like Kitty). Drop the per-frame cache and emit-tracking keys so
      # the next render re-encodes and re-emits. Mirrors
      # `Media::Cells#reset_sample_cache`.
      protected def reset_sample_cache : Nil
        reset_payload_cache
      end

      # Drops the per-frame payload cache and all emit-tracking keys. Shared by
      # every entry point that invalidates the encoded-frame state (`#load`,
      # `#clear_image`, `#reset_sample_cache`, the `double_buffer=`/`z=` setters).
      # Deliberately does NOT reset `@anim_checked`: the first-paint auto-play
      # probe re-arms only in `#load`/`#clear_image` (the two documented source
      # changes), so a cache drop from `#fit=`/`double_buffer=`/`z=` on a stopped
      # animation/video never silently resumes playback.
      private def reset_payload_cache : Nil
        @frame_payloads.clear
        @payload_geom = nil
        @payload = nil
        @payload_key = nil
        @emitted_key = nil
      end

      # (Re)paints the graphic at the widget's current position. Runs after every
      # window render so it stays on top of the freshly-drawn cells; skips while
      # hidden or detached. Wraps the emit in DECSC/DECRC so the terminal cursor
      # (and thus Crysterm's positioning on the next frame) is left untouched.
      private def redraw_image
        # `visible?` only consults THIS widget's own flag. Unlike the cell-render
        # pass (which skips hidden subtrees naturally), this overlay runs as a
        # standalone `Rendered` listener, so it must also bail when an ANCESTOR
        # is hidden: the widget is then off-window, the hidden ancestor has no
        # rendered position, and resolving coords against it (`coords(true)`
        # -> `last_rendered_position`) would raise instead of returning nil,
        # crashing the render-loop fiber. `#visible_in_tree?` walks the parent
        # chain, mirroring the tree-aware visibility `Capture` uses.
        return unless visible_in_tree?
        s = window? || return
        return unless has_image?
        ensure_animation
        # Draw into the *content* area, inside any border/padding (`#overlay_rect`).
        # An undrawable position (hidden, zero-sized, or slid to a negative
        # origin) returns nil: if the graphic was previously on window, erase it
        # now. `#clear_overlay` runs `#overlay_cleared` → `#graphic_cleared` (the
        # Kitty `a=d` delete), invalidates the old cells once, and nils
        # `@last_drawn` so this doesn't loop. Without it, a Kitty layer slid to a
        # negative origin floats at its last position forever (and every
        # backend needlessly re-invalidates the stale rect each frame).
        unless rect = content_rect
          clear_overlay if @last_drawn
          return
        end
        xi, yi, cols, rows = rect

        pw, ph = target_pixels(cols, rows)
        ox, oy = origin_pixels(xi, yi)
        payload = payload_for(pw, ph, ox, oy, cols, rows) || return

        # Sixel/ReGIS get overdrawn by the cells Crysterm flushes each frame, so
        # they must be re-emitted every render. A Kitty image is a separate
        # layer the cells don't touch, so it's emitted only when it actually
        # changes (new frame/move/resize), avoiding flicker and re-transmits.
        unless repaint_every_frame?
          if @emitted_key == @payload_key
            @last_drawn = {xi, yi, cols, rows}
            return
          end
        end

        # Pre-size the builder to the payload plus the fixed control-sequence
        # wrapper (BSU/DECSC/CUP/DECRC/ESU ≈ a few dozen bytes), so a multi-MB
        # sixel/ReGIS payload is streamed in without the builder's default
        # 64-byte buffer doubling (and re-copying) its way up every emit.
        io = String::Builder.new(payload.bytesize + 64)
        io << "\e[?2026h" if double_buffer?               # BSU: begin synchronized update
        io << "\e7"                                       # DECSC: save cursor
        io << "\e[" << (yi + 1) << ';' << (xi + 1) << 'H' # CUP to content top-left (1-based)
        # `#emit_payload` runs once per *emit* (not per cache-fill), letting a
        # double-buffering backend choose its target buffer by emit order rather
        # than baking it into the cached bytes. Reached only on a real emit (past
        # the emit-skip above), so any per-emit state it advances stays in sync.
        # Streams straight into `io`, avoiding a full substituted-payload copy per
        # frame (see `Media::Kitty#emit_payload`).
        emit_payload io, payload
        io << "\e8"                         # DECRC: restore cursor
        io << "\e[?2026l" if double_buffer? # ESU: end synchronized update — present atomically
        s.tput._oprint io.to_s
        s.tput.flush

        @emitted_key = @payload_key
        @last_drawn = {xi, yi, cols, rows}
      end

      # Whether the graphic must be re-emitted on every window render (true when
      # the terminal's cells overdraw it, e.g. sixel/ReGIS). Backends on a
      # separate layer the cells don't touch (Kitty) override this to false.
      protected def repaint_every_frame? : Bool
        true
      end

      # Last-mile transform applied to a payload at emit time, once per emit.
      # Default is identity; `Media::Kitty` overrides it to substitute the
      # double-buffer image id per emit (so buffer alternation follows emit
      # order even when the payload itself is served from the per-frame cache).
      # Public so the emit-order contract can be exercised directly.
      def finalize_payload(payload : String) : String
        payload
      end

      # Streams the emit-time-finalized *payload* straight into *io*, the hot
      # path used by `#redraw_image` once per emit. The default routes through
      # `#finalize_payload` (identity for the pixel-exact backends). `Media::Kitty`
      # overrides it to interleave cached literal segments with the concrete image
      # ids, avoiding the per-frame full-payload copy the `String` return of
      # `#finalize_payload` forces.
      protected def emit_payload(io : String::Builder, payload : String) : Nil
        io << finalize_payload(payload)
      end

      # Draw into the *content* area, inside any border/padding (the in-band
      # erase/track rectangle the shared `Media::ScreenOverlay` lifecycle uses).
      protected def overlay_rect(pos) : Tuple(Int32, Int32, Int32, Int32)
        xi = pos.xi + ileft
        yi = pos.yi + itop
        {xi, yi, (pos.xl - iright) - xi, (pos.yl - ibottom) - yi}
      end

      # The graphic is only on window once an image is present — a loaded file
      # or a directly-injected in-memory source (`Media::Base#bitmap=`, the
      # `Graph::Canvas` path, which leaves `@file` nil but sets `@source`).
      protected def overlay_visible? : Bool
        has_image?
      end

      # Whether this backend currently has something to draw: a loaded file path
      # or an injected in-memory source. The paint/erase/capture lifecycle keys
      # on this rather than `@file` alone, so a bitmap-fed graphic still renders.
      protected def has_image? : Bool
        !(@file.nil? && @source.nil?)
      end

      # On erase, give a separate-layer backend (Kitty) the chance to delete its
      # image, and drop the emit-skip key so a re-show re-emits.
      protected def overlay_cleared(s : ::Crysterm::Window)
        graphic_cleared s
        @emitted_key = nil
      end

      # Hook for backends whose pixels are NOT erased by re-emitting the cells
      # underneath (re-emitted text covers sixel/ReGIS, but not a Kitty image, a
      # separate layer that must be explicitly deleted). Called from
      # `#overlay_cleared` before the cells are invalidated. No-op by default.
      protected def graphic_cleared(s : ::Crysterm::Window)
      end

      private def teardown
        stop
        teardown_overlay_listeners
      end
    end
  end
end
