require "./base"
require "./screen_overlay"

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
    # The pixels here are owned by the terminal, not Crysterm's cell buffer, so
    # this class reuses the overlay erase/redraw lifecycle: the graphic is
    # (re)painted *after* the window flushes each frame's cells
    # (`Event::Rendered`), and the cells under the previous position are
    # force-re-emitted when the widget moves or hides, so the terminal's own
    # text rendering covers the stale graphic.
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
      # partial/torn frame. Terminals that don't understand 2026 ignore the
      # wrapper, so this is always safe to leave on.
      getter? double_buffer : Bool = true

      # The double-buffer flag changes the *shape* of the encoded per-frame
      # payload, which is memoized per geometry, so the cache must be dropped
      # here — a plain assignment keeps serving bytes built under the old mode.
      def double_buffer=(v : Bool) : Bool
        unless v == @double_buffer
          @double_buffer = v
          reset_payload_cache
          on_double_buffer_changed v
        end
        v
      end

      # Hook run after `double_buffer` actually changes, for a backend that must
      # emit terminal state the cache drop can't reach (e.g. deleting a
      # now-unused second buffer left placed on screen). No-op by default.
      protected def on_double_buffer_changed(v : Bool)
      end

      # Shared `dither=` for the in-band graphics backends that expose a
      # settable `dither` (`Media::Sixel`, `Media::Regis`):
      # `dither` is not part of the payload cache key
      # (`#payload_for` keys on geometry only), so a plain assignment would
      # silently keep re-emitting the stale cached payload. Drop it and request
      # a render, but only on an actual change.
      #
      # Routes the actual write through `#store_dither`, a one-line hook each
      # subclass implements against its own `@dither` ivar, rather than writing
      # `@dither` directly here: `Media::Graphics` never declares/initializes
      # that ivar itself (only its subclasses do, at differing defaults —
      # `Auto` for Sixel, `None` for Regis), so a direct `@dither =` here would
      # make Crystal infer the ivar as nilable in this class and conflict with
      # the subclasses' non-nilable `getter dither : Media::Dither = ...`
      # declarations. Not `abstract def`: other `Media::Graphics` subclasses
      # (`Kitty`, `Iterm`) have no `dither` at all and must not be forced to
      # implement it.
      #
      # `Media::Ansi` (a `Media::Cells`, not a `Media::Graphics`) carries the
      # same shape but a different invalidation hook (`clear_frame_derived`, not
      # `reset_sample_cache` — a dithered *cell* plane, not an encoded payload)
      # and sits in a sibling hierarchy with no common ancestor closer than
      # `Media::Base`, so it keeps its own `dither=` rather than sharing this one.
      def dither=(v : Media::Dither) : Media::Dither
        unless v == dither
          store_dither v
          reset_sample_cache
          update!
        end
        v
      end

      # Original (undecoded) bytes cache, for backends that transmit the file
      # as-is (iTerm2). The decoded `@source`/frames live in `Media::Base`.
      @raw : Bytes?

      # Latches a failed `#raw_bytes` read so a broken source (unreachable URL,
      # deleted/unreadable file) isn't re-attempted on every rendered frame.
      # Cleared by `#load`/`#clear_image` so a corrected source is retried.
      @raw_failed = false

      # Set once the first paint has checked whether the source is animated.
      @anim_checked = false

      # Per-frame payload cache for the *current* geometry, keyed by animation
      # frame index, so a looping animation re-encodes each frame at most once
      # per size. Cleared when the geometry (size/origin/fit) changes; bounded
      # by the frame count. `@payload`/`@payload_key` track the payload
      # currently selected, for the emit-skip.
      @frame_payloads = {} of Int32 => String
      # The pixel size of the bitmap each cached frame payload was encoded
      # from, by frame index, beside `@frame_payloads` — what a source
      # rectangle of the transmitted picture is measured in (`Media::Kitty`).
      @frame_dims = {} of Int32 => Tuple(Int32, Int32)
      # The pixel size of the bitmap `@payload` was encoded from, when known.
      @payload_dims : Tuple(Int32, Int32)?
      @payload_geom : Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32)?
      @payload : String?
      @payload_key : Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)?
      # The key whose payload was last actually emitted, for backends that don't
      # re-emit every frame.
      @emitted_key : Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)?

      # Scratch `RenderedGeometry` reused by `#content_rect`, called every
      # `Rendered`, to avoid a heap allocation per call (`coords` with no
      # `into:` allocates fresh). Each call fully unpacks the result into a
      # plain `Tuple` before returning, so reusing one buffer across calls —
      # even nested ones within the same render pass — is safe.
      @content_lpos : RenderedGeometry = RenderedGeometry.new

      def initialize(
        @file = nil,
        # 0 = auto-detect from the terminal (falls back to a typical xterm cell).
        @cell_pixel_width = 0,
        @cell_pixel_height = 0,
        @fit : Media::Fit = Media::Fit::Stretch,
        animate : Bool | Timer = true,
        speed : Float64 = 1.0,
        @double_buffer : Bool = Crysterm::Config.media_double_buffer,
        **box,
      )
        super **box
        # Route through the validating setter so speed: 0/NaN/Infinity is clamped
        # to 1.0 — the pacers divide by @speed and would otherwise crash.
        self.speed = speed
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

        # Repaint after the window finishes each render (cells flushed by then,
        # so the graphic lands on top). When built detached, this defers
        # registration — and a real cell-size re-resolve — until attached.
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

      # On (deferred) attach, re-resolve the real cell size from the window,
      # then register the overlay listeners.
      protected def on_overlay_window(s : ::Crysterm::Window)
        resolve_cell_pixels s
        register_overlay_listeners s
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
      # being shown or, for a still, the decoded canvas. Lets a scaling backend
      # avoid transmitting more pixels than the source has (for video, that
      # would re-upload a full-window frame every tick).
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
        reset_graphic_source_state
        update!
      end

      # Clears the loaded image, erasing its graphic from the window.
      def clear_image
        clear_overlay
        super # stop + drop file/source/frames
        reset_graphic_source_state
      end

      # Drops the cached undecoded bytes + animation-probe latch and the decoded
      # payload cache, so the next draw re-decodes from the current source.
      private def reset_graphic_source_state : Nil
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
        return if @raw_failed
        file = @file || return
        @raw =
          if file =~ /^https?:/
            Widget::Media.fetch file
          else
            File.read(file).to_slice
          end
      rescue
        @raw_failed = true
        nil
      end

      # In-band terminal graphics are visible to the terminal, so they are
      # composited into captures.
      def capture_pixels? : Bool
        true
      end

      # The non-empty content cell-rectangle `{xi, yi, cols, rows}` this widget
      # currently occupies — its rendered coords inset by border/padding — or
      # `nil` when it has no rendered position or is zero-sized.
      private def content_rect : Tuple(Int32, Int32, Int32, Int32)?
        pos = coords(rendered: true, into: @content_lpos) || return
        xi, yi, cols, rows = overlay_rect pos
        return if cols <= 0 || rows <= 0
        # A partially-offscreen widget (negative origin) is not drawable: the
        # emitted CUP would be clamped (`\e[0;…H` — one row off, unclipped) or
        # malformed (`\e[-1;…H`, splatting the image at the cursor), and
        # `@last_drawn` would record the negative rect, so the erase pass would
        # target the wrong cells. Treat it like a hidden widget.
        return if xi < 0 || yi < 0
        {xi, yi, cols, rows}
      end

      # Current frame resampled to the widget's content cell-box × font cell
      # size, plus its content top-left cell origin, so the capture renderer
      # composites it where the terminal draws the graphic. Must mirror
      # `#redraw_image`'s geometry. `nil` while hidden or with no image.
      def capture_layer(font_w : Int32, font_h : Int32) : Tuple(PNGGIF::Bitmap, Int32, Int32)?
        return unless visible?
        return unless has_image?
        xi, yi, cols, rows = content_rect || return
        bmp = fit_bitmap(cols * font_w, rows * font_h) || return
        {bmp, xi, yi}
      end

      # Resamples the source into a *bw*×*bh* pixel bitmap fit per `#fit` (pixels
      # are square, so no aspect correction). Re-derives from the cached source
      # on every size change, making the backends resize-aware. `pixel_box`
      # marks the box as true device pixels, so `Fit::None` draws the source at
      # its native pixel size instead of a cell footprint (which would halve its
      # height by the cell aspect ratio).
      protected def fit_bitmap(bw : Int32, bh : Int32, transient : Bool = false) : PNGGIF::Bitmap?
        src = source || return
        frame = @src_frames.try(&.[@anim_index]?).try &.[0]
        # Reuse fast paths (opt-in via `media.reuse_buffers`): a *transient*
        # caller feeds the bitmap straight into `#encode` and discards it, so
        # the result need not survive the next repaint. Only safe for transient
        # callers: anything that hands the bitmap to an external holder
        # (`capture_layer`) needs a copy stable across frames.
        if transient && Config.media_reuse_buffers
          # When the source already matches the target box the resample would
          # be a pure identity copy — hand the source pixels over instead.
          cand = frame || src.bmp
          sw, sh = Media.dims(cand)
          return cand if sw == bw && sh == bh
          # Otherwise compose into scratch canvases reused across frames, so an
          # animated re-encode (streaming video, an injected canvas at a
          # non-native size, a scaled GIF's first loop) allocates no fresh
          # resample/letterbox bitmap per frame.
          sample_scratch = (@compose_sample_scratch ||= PNGGIF::Bitmap.new)
          place_scratch = (@compose_place_scratch ||= PNGGIF::Bitmap.new)
          return Media::Fitting.compose src, frame, bw, bh, @fit, 1.0, pixel_box: true,
            sample_into: sample_scratch, place_into: place_scratch
        end
        Media::Fitting.compose src, frame, bw, bh, @fit, 1.0, pixel_box: true
      end

      # Reusable compose canvases for the transient encode path (see
      # `#fit_bitmap`); nil until `media.reuse_buffers` first exercises them.
      @compose_sample_scratch : PNGGIF::Bitmap? = nil
      @compose_place_scratch : PNGGIF::Bitmap? = nil

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
        # This probe is a load-time entry point: it may open the live video
        # decoder. `@anim_checked` guards it, so a post-`stop` render never
        # re-opens it — only `#load`/`#clear_image` re-arm it.
        src = source(open_stream: true) || return
        play if src.frames && animate?
      end

      # Builds the full escape payload for a *bw*×*bh* box: resamples the source
      # (fit into the box) and hands the bitmap to `#encode`. Backends that
      # transmit the original file bytes (iTerm2) override this and use
      # `#raw_bytes` + the cell box instead.
      protected def build_payload(bw : Int32, bh : Int32, ox : Int32, oy : Int32,
                                  cols : Int32, rows : Int32) : String?
        bmp = fit_bitmap(bw, bh, transient: true) || return
        real_w, real_h = Media.dims(bmp)
        return if real_w == 0 || real_h == 0
        @frame_dims[@anim_index] = {real_w, real_h}
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
          @frame_dims.clear
        end
        p = @frame_payloads[@anim_index]? || begin
          built = build_payload(bw, bh, ox, oy, cols, rows) || return
          @frame_payloads[@anim_index] = built
          built
        end
        @payload = p
        @payload_dims = @frame_dims[@anim_index]? || {bw, bh}
        @payload_key = {bw, bh, ox, oy, cols, rows, @fit.value, @anim_index}
        p
      end

      # Streaming reuses frame index 0 with new content each tick. Drop its
      # cached payload so it re-encodes, and clear `@emitted_key` so the
      # change-skip in `#redraw_image` doesn't treat the new frame as
      # already-emitted and freeze on frame 0.
      protected def invalidate_frame(idx : Int32)
        @frame_payloads.delete idx
        @frame_dims.delete idx
        @emitted_key = nil
      end

      # A directly-injected bitmap replaces the source without changing the box
      # geometry, so the geometry-keyed payload cache would keep serving the
      # previous frame's bytes and freeze the graphic on the stale image. Drop
      # the per-frame cache and emit-tracking keys so the next render re-encodes
      # and re-emits.
      protected def reset_sample_cache : Nil
        reset_payload_cache
      end

      # Drops the per-frame payload cache and all emit-tracking keys, for every
      # entry point that invalidates the encoded-frame state. Deliberately does
      # NOT reset `@anim_checked`: the first-paint auto-play probe re-arms only
      # on a real source change, so a cache drop on a stopped animation/video
      # never silently resumes playback.
      private def reset_payload_cache : Nil
        @frame_payloads.clear
        @frame_dims.clear
        @payload_geom = nil
        @payload = nil
        @payload_dims = nil
        @payload_key = nil
        @emitted_key = nil
        @piece_key = nil
        @piece_payloads = nil
      end

      # (Re)paints the graphic at the widget's current position. Runs after every
      # window render so it stays on top of the freshly-drawn cells; skips while
      # hidden or detached. Wraps the emit in DECSC/DECRC so the terminal cursor
      # (and thus Crysterm's positioning on the next frame) is left untouched.
      private def redraw_image
        # Must be `visible_in_tree?`, not `visible?` (this widget's own flag):
        # as a standalone `Rendered` listener this runs even under a hidden
        # ancestor, which has no rendered position, and resolving coords against
        # it raises rather than returning nil — crashing the render-loop fiber.
        return unless visible_in_tree?
        s = window? || return
        return unless has_image?
        ensure_animation
        # An undrawable position (hidden, zero-sized, or slid to a negative
        # origin) returns nil: erase the graphic if it was previously on window,
        # else a separate-layer graphic floats at its last position forever.
        # `#clear_overlay` nils `@last_drawn`, so this can't loop.
        unless rect = content_rect
          clear_overlay if @last_drawn
          return
        end
        xi, yi, cols, rows = rect

        pw, ph = target_pixels(cols, rows)
        ox, oy = origin_pixels(xi, yi)
        payload = payload_for(pw, ph, ox, oy, cols, rows) || return

        # What is stacked above the picture — a menu, a torn-off menu, a
        # dialog, a tool tip — must stay on top of it. `nil` when nothing
        # covers it, else the uncovered parts of the content box, relative to
        # its top-left cell (empty when it is covered whole).
        pieces = presented_pieces xi, yi, cols, rows
        reemit_newly_covered s, xi, yi, cols, rows, pieces

        # Sixel/ReGIS get overdrawn by the cells Crysterm flushes each frame, so
        # they must be re-emitted every render. A Kitty image is a separate
        # layer the cells don't touch, so it's emitted only when it actually
        # changes (new frame/move/resize, or what covers it), avoiding flicker
        # and re-transmits — or when the terminal may have lost it since: cells
        # written over its rectangle (a terminal keeping images in its cells
        # erases them, and the full re-emission once the terminal's colors are
        # known writes every cell, blanks included) or a screen clear (`ED 2`
        # deletes kitty's images), which left the picture covered until it
        # moved (`#overdrawn?`).
        if repaint_every_frame?
          if pieces
            emit_pieces s, xi, yi, cols, rows, ox, oy, pieces
            @emitted_key = @payload_key
            @last_drawn = {xi, yi, cols, rows}
            return
          end
        elsif @emitted_key == @payload_key
          if pieces == @placed_pieces && !s.overdrawn?(xi, yi, cols, rows)
            @last_drawn = {xi, yi, cols, rows}
            return
          end
          # Only cells were written over it, or what covers it changed: a
          # backend whose terminal still holds the transmitted picture places
          # it again, the uncovered parts only, without its data.
          if !s.wiped? && (seq = place_again_seq(xi, yi, cols, rows, pieces))
            io = String::Builder.new(seq.bytesize + 32)
            io << "\e[?2026h" if double_buffer?
            io << "\e7" << seq << "\e8"
            io << "\e[?2026l" if double_buffer?
            s.tput._oprint io.to_s
            s.tput.flush
            @placed_pieces = pieces
            @last_drawn = {xi, yi, cols, rows}
            return
          end
        end

        # Pre-size to the payload plus the fixed control-sequence wrapper
        # (BSU/DECSC/CUP/DECRC/ESU ≈ a few dozen bytes), so a multi-MB payload
        # doesn't double the builder's default 64-byte buffer up on every emit.
        io = String::Builder.new(payload.bytesize + 64)
        io << "\e[?2026h" if double_buffer?               # BSU: begin synchronized update
        io << "\e7"                                       # DECSC: save cursor
        io << "\e[" << (yi + 1) << ';' << (xi + 1) << 'H' # CUP to content top-left (1-based)
        # Runs once per *emit*, not per cache-fill, letting a double-buffering
        # backend pick its target buffer by emit order rather than baking it
        # into the cached bytes. Reached only past the emit-skip above, so any
        # per-emit state it advances stays in sync. A covered picture is sent
        # without being placed, then placed in its uncovered parts.
        emit_payload io, payload, place: pieces.nil?
        if pieces
          place_again_seq(xi, yi, cols, rows, pieces).try { |placed| io << placed }
        end
        io << "\e8"                         # DECRC: restore cursor
        io << "\e[?2026l" if double_buffer? # ESU: end synchronized update — present atomically
        s.tput._oprint io.to_s
        s.tput.flush

        @emitted_key = @payload_key
        @placed_pieces = pieces
        @last_drawn = {xi, yi, cols, rows}
      end

      # The parts of the content box at (*xi*, *yi*), *cols* × *rows* cells,
      # that nothing stacked above this widget covers (`Widget#visible_region`),
      # as rectangles relative to its top-left cell — or `nil` when nothing
      # covers any of it, the common case, which presents the picture whole.
      private def presented_pieces(xi : Int32, yi : Int32, cols : Int32, rows : Int32) : Array(Rectangle)?
        box = Rectangle.new(xi, yi, cols, rows)
        region = visible_region(box)
        rects = region.rects
        return if rects.size == 1 && rects.unsafe_fetch(0) == box
        region.translated(-xi, -yi).rects
      end

      # The uncovered parts (`#presented_pieces`) the last frame presented, for
      # `#reemit_newly_covered`; `nil` when it was whole.
      @presented : Array(Rectangle)? = nil

      # Has the cells covered over the picture this frame emitted again, on
      # the next frame, when what covers it changed. Crysterm sends a cell only
      # when it differs from what it sent there before, and a blank cell of a
      # menu (its padding, the rest of a short entry's row) is the same blank
      # as the one under the picture: unsent, it would leave the terminal's
      # piece of the picture showing through the menu wherever the terminal
      # keeps pictures in its cells (sixel and iTerm2 images everywhere, Kitty
      # images in WezTerm). Sent again, it erases that piece; the uncovered
      # parts are then drawn around it.
      private def reemit_newly_covered(s : ::Crysterm::Window, xi : Int32, yi : Int32, cols : Int32, rows : Int32,
                                       pieces : Array(Rectangle)?) : Nil
        return if pieces == @presented
        @presented = pieces
        return unless pieces
        covered = Region.new(Rectangle.new(0, 0, cols, rows))
        pieces.each { |r| covered = covered.subtracted r }
        return if covered.empty?
        covered.rects.each do |r|
          s.invalidate_region xi + r.xi, xi + r.xl, yi + r.yi, yi + r.yl
        end
        s.update
      end

      # The uncovered parts (`#presented_pieces`) the graphic was last placed
      # in, `nil` when it was placed whole.
      @placed_pieces : Array(Rectangle)? = nil

      # The control sequence that places the graphic last emitted again, from
      # what the terminal kept of it, over the content box at (*xi*, *yi*),
      # *cols* × *rows* cells — whole when *pieces* is nil, else in each of
      # *pieces* (relative to the box, possibly none) only, removing any
      # placement left from before — cursor moves included; or nil to send it
      # whole (the default). Used when the frame wrote cells over the picture
      # but did not wipe the surface (`Window#wiped?`), when what covers it
      # changed, and after a covered picture was sent without being placed.
      protected def place_again_seq(xi : Int32, yi : Int32, cols : Int32, rows : Int32,
                                    pieces : Array(Rectangle)?) : String?
        nil
      end

      # The key (`@payload_key` and the pieces) `@piece_payloads` were built
      # for, and the payloads, one per piece, that `#emit_pieces` re-emits
      # every frame while it stands.
      @piece_key : Tuple(Tuple(Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32)?, Array(Rectangle))?
      @piece_payloads : Array(String)?

      # Paints a covered picture of a backend that draws into the cells
      # (sixel, ReGIS, iTerm2) as one picture per uncovered part (*pieces*,
      # relative to the content box at *xi*, *yi*), each cut from the frame
      # fitted to the whole box and drawn at its own cell, so the cells
      # stacked above it are never drawn over. The parts are encoded once per
      # frame and covering, and re-emitted each frame like a whole picture.
      private def emit_pieces(s : ::Crysterm::Window, xi : Int32, yi : Int32, cols : Int32, rows : Int32,
                              ox : Int32, oy : Int32, pieces : Array(Rectangle)) : Nil
        return if pieces.empty?
        key = {@payload_key, pieces}
        payloads = @piece_payloads
        unless payloads && @piece_key == key
          payloads = build_pieces(xi, yi, cols, rows, pieces) || return
          @piece_key = key
          @piece_payloads = payloads
        end
        io = String::Builder.new(payloads.sum(&.bytesize) + 32 * payloads.size + 32)
        io << "\e[?2026h" if double_buffer?
        io << "\e7"
        pieces.each_with_index do |r, k|
          io << "\e[" << (yi + r.y + 1) << ';' << (xi + r.x + 1) << 'H'
          io << payloads[k]
        end
        io << "\e8"
        io << "\e[?2026l" if double_buffer?
        s.tput._oprint io.to_s
        s.tput.flush
      end

      # The payload of each of *pieces* (see `#emit_pieces`): the current frame
      # fitted to the *cols* × *rows* box at `#piece_canvas_pixels`, cut at the
      # pieces' cell edges, each cut handed to `#piece_payload`.
      private def build_pieces(xi : Int32, yi : Int32, cols : Int32, rows : Int32,
                               pieces : Array(Rectangle)) : Array(String)?
        bw, bh = piece_canvas_pixels(cols, rows)
        bmp = fit_bitmap(bw, bh, transient: true) || return
        rw, rh = Media.dims(bmp)
        return if rw == 0 || rh == 0
        pieces.map do |r|
          px0 = r.x * rw // cols
          px1 = r.x_end * rw // cols
          py0 = r.y * rh // rows
          py1 = r.y_end * rh // rows
          px1 = px0 + 1 if px1 <= px0
          py1 = py0 + 1 if py1 <= py0
          w = Math.min(px1, rw) - px0
          cut = Array.new(py1 - py0) { |dy| bmp[Math.min(py0 + dy, rh - 1)][px0, w] }
          pox, poy = origin_pixels(xi + r.x, yi + r.y)
          piece_payload(cut, w, py1 - py0, pox, poy, r.width, r.height)
        end
      end

      # The pixel size a covered picture is fitted at before being cut into
      # its pieces, for a *cols* × *rows* box: `#target_pixels` by default.
      protected def piece_canvas_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        target_pixels(cols, rows)
      end

      # The escape sequence drawing *bmp* (`pw` × `ph` pixels, one piece of a
      # covered picture) over *cols* × *rows* cells at the cursor, its pixel
      # origin *ox*, *oy*: `#encode` by default.
      protected def piece_payload(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                                  cols : Int32, rows : Int32) : String
        encode(bmp, pw, ph, ox, oy, cols, rows)
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
      # path taken once per emit. The default routes through
      # `#finalize_payload` (identity for the pixel-exact backends). `Media::Kitty`
      # overrides it to interleave cached literal segments with the concrete image
      # ids, avoiding the per-frame full-payload copy the `String` return of
      # `#finalize_payload` forces.
      #
      # *place* false asks a backend that sends a picture and places it in one
      # sequence (Kitty) to send it only, for `#place_again_seq` to place;
      # one drawing into the cells ignores it.
      protected def emit_payload(io : String::Builder, payload : String, place : Bool = true) : Nil
        io << finalize_payload(payload)
      end

      # Draw into the *content* area, inside any border/padding (the in-band
      # erase/track rectangle the shared `Media::ScreenOverlay` lifecycle uses).
      protected def overlay_rect(pos) : Tuple(Int32, Int32, Int32, Int32)
        xi, xl, yi, yl = content_edges pos
        {xi, yi, xl - xi, yl - yi}
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
        @placed_pieces = nil
        @presented = nil
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
