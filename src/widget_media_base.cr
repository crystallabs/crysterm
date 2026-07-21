require "./widget/media"
require "./widget/box"

module Crysterm
  class Widget
    # Raised by an image backend asked for a feature it can't provide, when the
    # `image.unsupported` config option is `"error"`.
    class Media::UnsupportedError < Exception
    end

    # Common abstract base for every `Widget::Media` backend, formalizing the
    # backend contract (image source, fit, animation) so the factory
    # (`Widget::Media.new`) returns one type instead of a union.
    #
    # Families specialize it further:
    #
    # * `Media::Cells` — the image becomes character cells Crysterm owns (`Ansi`, `Glyph`).
    # * `Media::External` — an external helper paints the pixels (`Overlay`, `Ueberzug`).
    # * `Media::Graphics` — the terminal renders in-band escapes (`Sixel`, `Regis`, `Kitty`, `Iterm`).
    # * `Media::Tek` — a separate Tektronix window.
    #
    # Animation is **render-driven**: `#play` composites source frames once (in a
    # fiber), then a loop advances `#anim_index` and calls `request_render` at
    # each frame's delay; the backend samples the current frame in its own
    # `#render`. Backends whose terminal animates for them (iTerm2), or that
    # can't animate, opt out — the latter route `#play`/`#pause`/`#stop` through
    # `#unsupported`.
    abstract class Media::Base < Box
      # Path (or `http(s)` URL) of the loaded image.
      getter file : String? = nil

      # Loads *f* — the assignment spelling of `#load` (a bare `@file` write
      # that displayed nothing was a footgun). `nil` clears the image via
      # `#clear_image`.
      def file=(f : String?) : String?
        f ? load(f) : clear_image
        f
      end

      # How a still image is fit into a box whose aspect differs (see `Media::Fit`).
      getter fit : Media::Fit = Media::Fit::Stretch

      # Changes the fit mode, dropping any cached per-size sample so the next
      # render re-derives it. Only a genuine change invalidates, so a per-frame
      # reconcile (`Widget#update_background_media`) doesn't churn the cache.
      def fit=(new_fit : Media::Fit) : Media::Fit
        unless new_fit == @fit
          @fit = new_fit
          reset_sample_cache
        end
        new_fit
      end

      # Playback speed multiplier for animations (1.0 = native speed).
      getter speed : Float64 = 1.0

      # Clamps non-positive/non-finite speeds to native (1.0) so the playback
      # pacers (`#animate_loop`, `#stream_loop`) never divide by zero.
      def speed=(v : Float64) : Float64
        @speed = (v.finite? && v > 0) ? v : 1.0
      end

      # Whether to play animated (GIF/APNG) sources automatically.
      property? animate : Bool = true

      # The image decoded once at native resolution, via the process-wide
      # `Media.decode` cache.
      @source : PNGGIF::PNG? = nil

      # Composited animation source frames (`{bitmap, delay_ms}`). For an eager
      # image/video this is the full frame list, built once; for a *streaming*
      # video it's a single reused slot holding the current frame (see
      # `#stream_loop`).
      @src_frames : Array(Tuple(PNGGIF::Bitmap, Int32))? = nil

      # Whether playback is wanted. Single source of truth: the frame clock
      # checks it each tick, so setting it false ends the loop.
      getter? playing = false

      # Private frame clock advancing `#anim_index` over time, used for solo
      # playback (`animate: true`); nil when not playing or driven by a shared
      # clock instead.
      @animation : FrameClock? = nil

      # A shared frame clock (`animate: someTimer`). While set, playback advances
      # one frame per tick of that clock, in lockstep with every other widget on
      # it, instead of running `@animation`. Owned by the caller; the widget only
      # subscribes/unsubscribes.
      @clock : Timer? = nil

      # This widget's subscription to `@clock`, kept so it can unsubscribe on
      # pause/stop/destroy instead of leaving the shared clock poking a dead widget.
      @clock_sub : ::Crysterm::Event::Tick::Wrapper? = nil

      # Live streaming video decoder (Tier 2), when the source is a video
      # resolved to `VideoSource::Mode::Stream`; `nil` for eager sources.
      @stream : Media::VideoSource::Stream? = nil

      # Generation token for the self-paced streaming playback loop
      # (`#stream_loop`). Bumped on every `#play`/`#pause`/`#stop`; each loop
      # captures the value when spawned and exits as soon as it no longer
      # matches, so a pause→play within a frame period can't leave the old loop
      # fiber running alongside the new one. Exposed for tests.
      getter stream_gen : Int32 = 0

      # Set once a source fails to load, so `#source` returns `nil` without
      # re-attempting (re-opening ffmpeg) on every render. Reset on new file load.
      @load_failed = false

      # Memoized resolution of "is `@file` a stream-mode video?" (`nil` = not yet
      # resolved). Resolving runs `Media::VideoSource.mode`, which spawns an
      # `ffprobe` under the default `media.video_decode = auto`, and `#source` is
      # called on every rendered frame. Must be reset whenever `@file` changes so
      # a new file re-resolves.
      @stream_mode : Bool? = nil

      # Resolves the `animate:` constructor argument. `true`/`false` toggle
      # whether an animated source plays; a `Timer` enables playback *and*
      # drives it from that shared clock, syncing several widgets together.
      protected def setup_animate(animate : Bool | Timer) : Nil
        case animate
        in Timer
          @animate = true
          @clock = animate
        in Bool
          @animate = animate
        end
      end

      # Index of the frame currently shown. The animation loop advances it, but
      # it can also be set directly (after `#pause`) to drive playback from an
      # external clock — e.g. to keep several images in lockstep.
      getter anim_index : Int32 = 0

      # Whether a *finite* animation ran to completion and is now holding its last
      # frame. Distinguishes "done" from "paused mid-stream" so `#play` rewinds
      # before replaying instead of re-showing the last frame and re-stopping.
      @finished = false

      # Sets the shown frame. A *new* index marks the widget dirty so it repaints
      # under `OptimizationFlag::DamageTracking`: without that, an external clock
      # writing `anim_index =` changes the frame without notifying the damage
      # tracker and the selective composite keeps the stale cells (image appears
      # frozen). A no-op write leaves the dirty set untouched.
      def anim_index=(i : Int32) : Int32
        unless i == @anim_index
          @anim_index = i
          mark_dirty
        end
        i
      end

      # Loads *file* (decodes lazily via `#source`); the canonical verb every
      # backend implements (`#file=` is the assignment spelling).
      abstract def load(file : String)

      # Sets the backend's source directly from an in-memory RGBA bitmap instead
      # of decoding a file, wrapping it as a single-frame `PNGGIF::PNG` so the
      # sample/compose/render pipeline renders it unchanged. Clears any per-size
      # sample cache so a same-size update re-renders. Bitmap must be non-empty.
      def bitmap=(bmp : PNGGIF::Bitmap) : PNGGIF::Bitmap
        w, h = Media.dims(bmp)
        raise ArgumentError.new("Media#bitmap=: empty bitmap") if w <= 0 || h <= 0
        # Stop before swapping the source out from under a running animation,
        # else a zombie `FrameClock` keeps advancing at the old GIF's rate or a
        # streaming decoder stays open.
        stop
        @file = nil
        @load_failed = false
        @src_frames = nil
        @source = PNGGIF::PNG.from_frames([{bmp, 0}], w, h)
        reset_sample_cache
        bmp
      end

      # The backend's native pixel resolution for a *cols*×*rows* content box —
      # the size a bitmap must be allocated at to render crisply (no
      # resampling). Default is one pixel per cell.
      def native_resolution(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        {cols, rows}
      end

      # Physical width:height of one of this backend's device pixels (1.0 =
      # square), so circles stay round. Default assumes a ~1:2 cell.
      def native_pixel_aspect : Float64
        0.5
      end

      # Hook: drop any cached per-size sample so the next render re-derives it
      # from the newly set source. No-op here.
      protected def reset_sample_cache : Nil
      end

      # Clears the loaded image and stops any animation. Subclasses override to
      # also drop their own caches, calling `super` to run this base cleanup.
      def clear_image
        stop # closes the stream if one is open
        @file = nil
        @source = nil
        @src_frames = nil
        @anim_index = 0
        @finished = false
        @load_failed = false
        @stream_mode = nil # @file cleared: re-resolve on the next loaded file
      end

      # Common `#load` preamble: stop playback, point at the new *file*, and drop
      # the decoded source, frame list, and frame index so the next render
      # re-derives. Each backend then clears its own caches.
      protected def reset_source_state(file : String) : Nil
        stop
        @file = file
        @source = nil
        # Clear the failure latch, else `#source` early-returns nil forever after
        # any prior failed load.
        @load_failed = false
        @stream_mode = nil # new file: re-resolve the video decode mode (once)
        @src_frames = nil
        @anim_index = 0
      end

      # The decoded source image (cached), or `nil` if none/failed to load. For a
      # streaming video this opens the live decoder and returns its 1-frame
      # resampling vehicle (`@stream` then drives playback); otherwise decodes
      # eagerly via `Media.decode`. A failed open is not retried (`@load_failed`).
      #
      # Opening the live decoder (ffprobe ×2 + ffmpeg) is *explicit*: only the
      # playback/load entry points may pass `open_stream: true`. A render path
      # must not — it would re-launch ffmpeg with `@playing` false, so nothing
      # drains the pipe and the decoder blocks forever, undoing `#stop`. Such
      # callers get `nil` and fall back to their retained sample/payload of the
      # last shown frame.
      protected def source(open_stream : Bool = false) : PNGGIF::PNG?
        if s = @source
          return s
        end
        return if @load_failed
        file = @file || return
        if stream_mode_source? file
          return unless open_stream
          if st = Media::VideoSource::Stream.open(file)
            @stream = st
            @source = st.vehicle
          else
            @load_failed = true
            nil
          end
        else
          src = Media.decode file
          @load_failed = true if src.nil?
          @source = src
        end
      end

      # Whether *file* is a video resolved to *stream* decode mode, memoized for
      # `@file`'s lifetime. `Media::VideoSource.mode` spawns an `ffprobe`, so the
      # memo is what keeps a stopped, still-attached stream source from churning
      # a subprocess per rendered frame.
      private def stream_mode_source?(file : String) : Bool
        cached = @stream_mode
        return cached unless cached.nil?
        @stream_mode = Media::VideoSource.video?(file) && Media::VideoSource.mode(file).stream?
      end

      # Whether the composited source frames have been built yet (decode/composite
      # happens in a background fiber on first `#play`).
      def frames_ready? : Bool
        !@src_frames.nil?
      end

      # Whether this backend's pixels are *visible to the terminal* and so must
      # be composited into a capture. False here: `Cells` already lives in the
      # window's cell buffer (captured for free), while `External`/`Tek` are
      # painted by a program or window the terminal can't see.
      def capture_pixels? : Bool
        false
      end

      # Whether this backend's terminal-native graphic stacks *under* the cell
      # text (e.g. a Kitty placement with negative `z`), so `Capture.render`
      # must composite it before the text pass instead of after. False by
      # default (on-top stacking, the common case).
      def capture_under_text? : Bool
        false
      end

      # The current frame as a capture layer: an RGBA `PNGGIF::Bitmap` sized to
      # the widget's content cell-box × (*font_w* × *font_h*) pixels, plus the
      # content's top-left cell coordinates `{bmp, cell_xi, cell_yi}`. `nil` by
      # default.
      def capture_layer(font_w : Int32, font_h : Int32) : Tuple(PNGGIF::Bitmap, Int32, Int32)?
        nil
      end

      # Starts (or resumes) animation playback. Source frames are composited once
      # (capped resolution, in a background fiber so a large GIF doesn't block
      # first paint); the loop then advances the frame index and re-renders.
      def play
        return if @playing
        # Rewind a finite animation that ran to completion, else the loop starts
        # at the last frame and immediately re-completes. Gate on the completion
        # flag, not the index: `#pause` keeps `@anim_index` for resume.
        if @finished
          @anim_index = 0
          @finished = false
        end
        png = source(open_stream: true) # (re)opens the streaming decoder when applicable
        return unless png

        # Only a *genuine* animation plays: a live video stream, or a decoded
        # source with more than one frame. A single-frame source injected via
        # `#bitmap=` has non-nil `frames` (unlike a decoded still), and without
        # this guard auto-play would spin a one-frame loop re-rendering forever
        # at the minimum interval.
        return unless @stream || ((fr = png.frames) && fr.size > 1)

        @playing = true

        if @stream
          # Streaming video: pull frames into a single reused slot. On a shared
          # clock the clock pulls one frame per tick in lockstep; otherwise a
          # private fiber pulls at the video's own rate.
          @src_frames = nil
          if @clock
            subscribe_clock
          else
            # Capture a fresh generation for this loop; a superseding
            # play/pause/stop bumps `@stream_gen` so this fiber exits.
            gen = (@stream_gen += 1)
            spawn stream_loop(gen)
          end
        elsif @src_frames
          start_playback
        else
          spawn do
            Fiber.yield # let the current layout paint before the heavy build
            sw, sh = Media::Fitting.source_size png
            frames = png.animation_cellmaps(sw, sh, 1.0)
            # Generation guard: a `#load`/`#bitmap=` during the composite
            # replaced the source, and playback state belongs to the new
            # session now. Committing anyway would clobber the new source's
            # frames with the old GIF's, or kill its playback below.
            next unless @source.same?(png)
            @src_frames = frames
            if frames && !frames.empty? && @playing
              start_playback
            else
              @playing = false
            end
          end
        end
      end

      # Begins advancing frames once `@src_frames` exists: drive from the shared
      # clock if given, else run a private `FrameClock`.
      private def start_playback
        if @clock
          subscribe_clock
        else
          animate_loop
        end
      end

      # Subscribe to the shared clock; each tick advances this widget by one frame.
      # Idempotent — drops any prior subscription first.
      private def subscribe_clock : Nil
        c = @clock || return
        unsubscribe_clock
        @clock_sub = c.on(::Crysterm::Event::Tick) { tick_frame }
      end

      # One shared-clock tick of playback: for a streaming source, pull and
      # present the next live frame; otherwise step the prebuilt frame index.
      # All widgets on the same clock advance together, one frame per tick.
      private def tick_frame : Nil
        return unless @playing
        if st = @stream
          # A false return means EOF with a failed restart (or playback stopped)
          # and must end playback, else the clock keeps calling `advance_stream`
          # every tick, relaunching (and killing) an ffmpeg per frame forever.
          unless advance_stream st
            # Only end playback for a stream we still own: a stop→play during
            # restart's yield window replaces `@stream`, and the false is then
            # about the discarded stream — the new session owns `@playing` and
            # the clock subscription now.
            if st.same?(@stream)
              @playing = false
              unsubscribe_clock
            end
          end
        else
          advance_shared
        end
      end

      # Drop this widget's subscription to the shared clock (without stopping the
      # clock itself — other widgets may share it).
      private def unsubscribe_clock : Nil
        if (c = @clock) && (w = @clock_sub)
          c.off ::Crysterm::Event::Tick, w
        end
        @clock_sub = nil
      end

      # One frame per shared-clock tick (wrapping). The clock's own cadence sets
      # the rate, so per-frame GIF delays aren't honored — the tradeoff for
      # keeping several widgets in exact lockstep off one clock.
      private def advance_shared : Nil
        return unless @playing
        src = @src_frames
        return if src.nil? || src.empty?
        @anim_index = (@anim_index + 1) % src.size
        request_render
      end

      # Pauses playback on the current frame. A streaming decoder is left open
      # (ffmpeg blocks on the full pipe) so `#play` resumes promptly.
      def pause
        @playing = false
        @stream_gen += 1 # retire any running stream loop
        @animation.try &.stop
        unsubscribe_clock
      end

      # Stops playback and resets to the first frame. A streaming decoder is
      # closed and dropped (reaping ffmpeg); the next `#play` re-opens it via
      # `#source`.
      def stop
        @playing = false
        @stream_gen += 1 # retire any running stream loop
        @animation.try &.stop
        unsubscribe_clock
        @anim_index = 0
        @finished = false
        if st = @stream
          @stream = nil
          @source = nil # force `#source` to re-open the stream on next play
          st.close
        end
      end

      # Frame clock: advance the frame index over time and trigger a render.
      # Honours `speed` and the image's loop count (`num_plays`; 0 = loop
      # forever). Each tick sets the next sleep to that frame's own delay, so
      # GIFs keep their variable per-frame timing.
      private def animate_loop
        src = @src_frames
        return unless src
        png = source
        num_plays = png ? png.num_plays : 0
        plays = 0

        # Drop any previous clock so a rapid stop→play can't leave two fibers
        # advancing the same index.
        @animation.try &.stop
        # Advance the index at the START of each tick (the FrameClock fires its
        # first tick immediately, so `first` presents frame 0 unadvanced), THEN
        # render and set the interval from the frame actually displayed — so
        # each frame is shown for its OWN delay, including frame 0.
        first = true
        @animation = FrameClock.new((src[@anim_index]?.try(&.[1]) || 100).milliseconds) do |clock|
          if @playing
            unless first
              @anim_index += 1
              if @anim_index >= src.size
                plays += 1
                if num_plays > 0 && plays >= num_plays
                  # Finite animation done: hold the final frame instead of
                  # wrapping to 0, so the last render doesn't snap back to the start.
                  @anim_index = src.size - 1
                  @playing = false
                  @finished = true
                else
                  @anim_index = 0
                end
              end
            end
            first = false

            request_render

            delay = src[@anim_index]?.try(&.[1]) || 100
            ms = (delay / @speed).to_i
            ms = 1 if ms < 1
            clock.interval = ms.milliseconds # honor this frame's own delay
          end
          # End the clock once playback is no longer wanted, so any `@playing =
          # false` (pause/stop/num_plays) stops the loop on the next tick.
          clock.stop unless @playing
        end
        @animation.try &.start
      end

      # Background fiber for a *streaming* video: pull frames from the live
      # ffmpeg decoder into a single reused `@src_frames` slot and re-render —
      # constant memory regardless of length. Honours `speed`; stops when
      # `@playing` clears (`#stop` closes the pipe, unblocking a pending read).
      private def stream_loop(gen : Int32)
        stream = @stream || return
        # Deadline-based pacing: decode + render takes real time, so a plain
        # `sleep(delay)` drifts the video slower than its true fps. Advance a
        # deadline by the frame period and sleep only the remainder.
        next_at = Time.instant
        # Exit as soon as a newer play/pause/stop has bumped the generation,
        # even if `@playing` was flipped back to true under us by a fresh loop.
        while @playing && gen == @stream_gen
          break unless advance_stream stream

          ms = stream.delay / @speed
          ms = 1.0 if ms < 1
          next_at += ms.milliseconds
          now = Time.instant
          if next_at > now
            sleep(next_at - now)
          else
            next_at = now # fell behind: don't accumulate a catch-up burst
          end
        end
        if gen == @stream_gen
          # Still the live loop: end playback (EOF/close reached the loop).
          @playing = false
        elsif !stream.same?(@stream)
          # Superseded, and our captured stream was discarded: close it to reap
          # its ffmpeg. Don't touch `@playing` — the loop that replaced us owns
          # it now.
          stream.close
        end
      end

      # Pulls the next live frame from *stream* into the single reused
      # `@src_frames` slot, drops the backend's cached render for it, and
      # re-renders; at end-of-stream the decoder restarts. Returns false when
      # the stream ended and couldn't be reopened (or playback stopped), so the
      # caller halts.
      private def advance_stream(stream) : Bool
        bmp = stream.next_frame
        if bmp.nil?
          return false unless @playing
          # Only loop a stream we still own. A superseded loop reaching EOF must
          # not `restart` a discarded stream — that relaunches an ffmpeg on an
          # object nothing owns (never closed/reaped).
          return false unless stream.same?(@stream)
          restarted = stream.restart # loop the video
          # Re-check ownership AFTER restart: its yield points let a `stop` or a
          # new play disown this stream mid-restart. A `stop` landing between
          # `close` and `launch` finds `@process` nil and reaps nothing, so only
          # we can close the ffmpeg `restart` relaunches. A failed restart while
          # disowned is an artifact of the disowning — don't latch `@load_failed`.
          unless stream.same?(@stream)
            stream.close
            return false
          end
          # Latch a permanently failed restart (file deleted/truncated
          # mid-playback) so no playback path retries a dead source every frame.
          unless restarted # bail if the video won't reopen
            @load_failed = true
            return false
          end
          bmp = stream.next_frame || return false
        end
        delay = stream.delay
        slot = (@src_frames ||= [{bmp, delay}])
        slot[0] = {bmp, delay}
        @anim_index = 0
        invalidate_frame 0 # the slot's content changed; drop any cached render
        request_render
        true
      end

      # Hook: a backend caches per-frame renders keyed by frame index; streaming
      # reuses index 0 with changing content, so the loop calls this to drop the
      # stale cache entry for *idx*. No-op by default.
      protected def invalidate_frame(idx : Int32)
      end

      # Called by a backend when asked to do something it can't. Consults the
      # `image.unsupported` config option: `Error` raises `UnsupportedError`,
      # anything else ignores it (the backend does what it can).
      protected def unsupported(feature : String) : Nil
        if Crysterm::Config.media_unsupported.error?
          raise Media::UnsupportedError.new("#{self.class.name}: #{feature} is not supported by this image backend")
        end
      end
    end

    # Abstract base for the **external-overlay** image backends — those whose
    # pixels are painted by a separate helper process in its own window over the
    # terminal (`Media::Overlay` via `w3mimgdisplay`, `Media::Ueberzug` via
    # `ueberzug`).
    #
    # These are inherently static: the helper shows one image, so there's no
    # render-driven animation loop. `animate?` is false and `#play` routes
    # through `Media::Base#unsupported`, following the `image.unsupported`
    # policy instead of silently doing nothing.
    #
    # The unified `fit` knob is advisory here: each helper's own scaling control
    # is what actually takes effect.
    abstract class Media::External < Media::Base
      # External overlays are static; never auto-animate.
      @animate = false

      # Scratch `RenderedGeometry` reused by `#overlay_geometry`, run every
      # `Rendered`, to avoid a heap allocation per redraw (`coords` with no
      # `into:` allocates fresh). The result is unpacked into a plain `Tuple`
      # before returning, so reusing one buffer across calls is safe.
      @overlay_geom_lpos : RenderedGeometry = RenderedGeometry.new

      # Animation is not supported by an external-helper overlay.
      def play
        unsupported "animation"
      end

      # Current cell rectangle (`{xi, yi, w, h}`) this widget should be
      # (re)painted at this frame, or `nil` if it shouldn't be painted at all —
      # hidden (directly or via an ancestor), detached, or with no resolvable
      # box yet. The `visible_in_tree?` guard is required: a standalone
      # `Rendered` listener must not resolve `coords(true)` against a hidden
      # ancestor with no rendered position, which raises and kills the render
      # fiber.
      protected def overlay_geometry : Tuple(Int32, Int32, Int32, Int32)?
        return unless visible_in_tree?
        window? || return
        pos = coords(true, into: @overlay_geom_lpos) || return
        {pos.xi, pos.yi, pos.xl - pos.xi, pos.yl - pos.yi}
      end
    end

    # Minimal *single post-render listener* lifecycle for image backends whose
    # pixels live outside Crysterm's cell buffer but — unlike `Media::ScreenOverlay`
    # — don't need the erase-on-move (`PreRender`) half or `@last_drawn`
    # cell-rectangle tracking:
    #
    # * `Media::Ueberzug` — an override-redirect helper window that stays on top,
    #   re-sending `add`/`remove` only when the cell rectangle changes.
    # * `Media::Tek` — a separate Tektronix window driven by its own PAGE-clear
    #   redraw, not by re-emitting cells.
    #
    # Both register a single `Rendered` listener and tear it down on destroy;
    # the shared listener-wrapper ivars and add/remove dance live here. Each
    # backend supplies just the paint block and any extra teardown.
    module Media::RenderHook
      # Window the listener was registered on, kept so it can be removed on
      # destroy even after the widget is detached (`#window?` is nil).
      @listener_screen : ::Crysterm::Window?
      @ev_rendered : ::Crysterm::Event::Rendered::Wrapper?

      # The paint block, kept for the widget's whole life (not one-shot): a
      # cross-window reparent needs it again to re-register the `Rendered`
      # listener on the new window.
      @render_hook_block : (::Crysterm::Event::Rendered ->)?

      # One-shot guard for the self lifecycle hooks, so re-registering the
      # window listener after a move doesn't stack duplicate
      # `Attached`/`Reparented`/`Detached` handlers on this widget.
      @render_hook_wired = false

      # Registers *block* to run after every window render on *s*, remembering
      # *s* and the wrapper so it can be removed later.
      protected def register_render_hook(s : ::Crysterm::Window, &block : ::Crysterm::Event::Rendered ->)
        @render_hook_block = block
        @listener_screen = s
        @ev_rendered = s.on(::Crysterm::Event::Rendered, &block)
        wire_render_hook_lifecycle
      end

      # Registers *block* now when a window is resolvable, else defers to the
      # `Attached`/`Reparented` hooks. A backend built detached (compose-then-attach,
      # or a parent not yet on a `Window`) has no window at construction, so
      # calling the raising `window` accessor here would crash.
      protected def register_render_hook_deferred(&block : ::Crysterm::Event::Rendered ->)
        if s = window?
          register_render_hook(s, &block)
        else
          @render_hook_block = block
          wire_render_hook_lifecycle
        end
      end

      # Wires this widget's own lifecycle hooks, exactly once per widget:
      #
      # * `Attached`/`Reparented` — wired unconditionally, not only for a detached
      #   construction, so a widget built already-attached still migrates its
      #   listener when later moved to a different window. The
      #   `@listener_screen` guard makes a same-window `Reparented` a no-op.
      # * `Detached` — a cross-window reparent emits `Detach(previous)` then
      #   `Attach(new)`: drop the old window's `Rendered` listener so the paint
      #   block stops firing off a window the widget no longer lives on, and the
      #   old window stops referencing `self`.
      private def wire_render_hook_lifecycle
        return if @render_hook_wired
        @render_hook_wired = true
        on(::Crysterm::Event::Attached) { try_register_render_hook_deferred }
        on(::Crysterm::Event::Reparented) { try_register_render_hook_deferred }
        on(::Crysterm::Event::Detached) { teardown_render_hook }
      end

      # Registers the retained block on the current window, guarded on
      # `@listener_screen` so a re-attach to the same window doesn't
      # double-register.
      private def try_register_render_hook_deferred
        return if @listener_screen
        s = window? || return
        blk = @render_hook_block || return
        @listener_screen = s
        @ev_rendered = s.on(::Crysterm::Event::Rendered, &blk)
      end

      # Removes the listener and forgets the window. The paint block is retained
      # so an `Attached` to another window can re-register it.
      protected def teardown_render_hook
        s = @listener_screen || return
        @ev_rendered.try { |w| s.off ::Crysterm::Event::Rendered, w }
        @ev_rendered = nil
        @listener_screen = nil
      end
    end
  end
end
