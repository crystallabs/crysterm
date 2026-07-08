require "./widget/media"
require "./widget/box"

module Crysterm
  class Widget
    # Raised by an image backend asked for a feature it can't provide, when the
    # `image.unsupported` config option is `"error"` (see `Media::Base#unsupported`).
    class Media::UnsupportedError < Exception
    end

    # Common abstract base for every `Widget::Media` backend. Formalizes the
    # backend contract (image source, fit, animation) so the factory
    # (`Widget::Media.new`) can return one type (`Media::Base`) instead of a union.
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
    # can't animate (external/static ones), opt out — the latter route
    # `#play`/`#pause`/`#stop` through `#unsupported`.
    abstract class Media::Base < Box
      # Path (or `http(s)` URL) of the loaded image.
      property file : String? = nil

      # How a still image is fit into a box whose aspect differs (see `Media::Fit`).
      property fit : Media::Fit = Media::Fit::Stretch

      # Playback speed multiplier for animations (1.0 = native speed).
      property speed : Float64 = 1.0

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

      # Whether playback is wanted. Single source of truth: every place that
      # sets it false ends the loop, since the frame clock checks it each tick.
      getter? playing = false

      # Private frame clock advancing `#anim_index` over time, used for solo
      # playback (`animate: true`); nil when not playing or driven by a shared
      # clock instead.
      @animation : FrameClock? = nil

      # A shared frame clock (a `Timer`) when the widget was created with
      # `animate: someTimer`. While set, playback advances one frame per tick of
      # that clock — in lockstep with every other widget on it — instead of
      # running its own `@animation`. Owned by the caller; the widget only
      # subscribes/unsubscribes.
      @clock : Timer? = nil

      # This widget's subscription to `@clock`, kept so it can unsubscribe on
      # pause/stop/destroy instead of leaving the shared clock poking a dead widget.
      @clock_sub : ::Crysterm::Event::Tick::Wrapper? = nil

      # Live streaming video decoder (Tier 2), when the source is a video
      # resolved to `VideoSource::Mode::Stream`; `nil` for eager sources.
      @stream : Media::VideoSource::Stream? = nil

      # Generation token for the self-paced streaming playback loop
      # (`#stream_loop`), mirroring `Media::Tek#anim_gen`. Bumped on every
      # `#play`/`#pause`/`#stop`; each `#stream_loop` captures the value when
      # spawned and exits as soon as it no longer matches. Without it a
      # pause→play or stop→play within a frame period would leave the old loop
      # fiber (still sleeping between frames) running alongside the new one —
      # double-speed playback, racing `restart`s, and a discarded ffmpeg that
      # nothing ever closes. Exposed for tests.
      getter stream_gen : Int32 = 0

      # Set once a source fails to load, so `#source` returns `nil` without
      # re-attempting (re-opening ffmpeg) on every render. Reset on new file load.
      @load_failed = false

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
      # frame. Distinguishes "done" from "paused mid-stream" so `#play` can rewind
      # before replaying (a completed loop leaves `@anim_index` at the last frame;
      # replaying without a rewind would only re-show that frame and re-stop).
      @finished = false

      # Sets the shown frame. Assigning a *new* index marks the widget dirty so it
      # repaints under `OptimizationFlag::DamageTracking` (on by default): unlike
      # the internal animation loops — which assign `@anim_index` directly and pair
      # it with `request_render` — an external clock writing `anim_index =` would
      # otherwise change the frame without notifying the damage tracker, so the
      # selective composite would carry over the stale cells and the image would
      # appear frozen. A no-op write (same index) leaves the dirty set untouched.
      def anim_index=(i : Int32) : Int32
        unless i == @anim_index
          @anim_index = i
          mark_dirty
        end
        i
      end

      # Loads *file* (decodes lazily via `#source`); the canonical implementation
      # each backend provides. `#set_image` is an alias.
      abstract def load(file : String)

      # Alias for `#load`, for API parity across backends.
      def set_image(file : String)
        load file
      end

      # Sets the backend's source directly from an in-memory RGBA bitmap instead
      # of decoding a file. Wraps it as a single-frame `PNGGIF::PNG` so the
      # existing sample/compose/render pipeline renders it unchanged. Entry point
      # `Graph::Canvas` uses to display a freshly painted frame; clears any
      # per-size sample cache so a same-size update re-renders. Bitmap must be
      # non-empty.
      def bitmap=(bmp : PNGGIF::Bitmap) : PNGGIF::Bitmap
        w, h = Media.dims(bmp)
        raise ArgumentError.new("Media#bitmap=: empty bitmap") if w <= 0 || h <= 0
        @file = nil
        @load_failed = false
        @src_frames = nil
        @source = PNGGIF::PNG.from_frames([{bmp, 0}], w, h)
        reset_sample_cache
        bmp
      end

      # The backend's native pixel resolution for a *cols*×*rows* content box —
      # the size `Graph::Canvas` should allocate its bitmap at to render crisply
      # (no resampling). Default is one pixel per cell; `Glyph` (sub-cell) and
      # `Graphics` (true-pixel) override it.
      def native_resolution(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        {cols, rows}
      end

      # Physical width:height of one of this backend's device pixels (1.0 =
      # square), for `Graph::Painter#pixel_aspect` so circles stay round.
      # Default assumes a ~1:2 cell. Overridden by `Glyph` (sub-cell) and
      # `Graphics` (true square pixels).
      def native_pixel_aspect : Float64
        0.5
      end

      # Hook: drop any cached per-size sample so the next render re-derives it
      # from the (newly set) source. No-op here; `Media::Cells` overrides it.
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
      end

      # The decoded source image (cached), or `nil` if none/failed to load. For a
      # streaming video this opens the live decoder and returns its 1-frame
      # resampling vehicle (`@stream` then drives playback); otherwise decodes
      # eagerly via `Media.decode`. A failed open is not retried (`@load_failed`).
      protected def source : PNGGIF::PNG?
        if s = @source
          return s
        end
        return nil if @load_failed
        file = @file || return nil
        if Media::VideoSource.video?(file) && Media::VideoSource.mode(file).stream?
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

      # Whether the composited source frames have been built yet (decode/composite
      # happens in a background fiber on first `#play`). Useful to a recorder
      # that wants to start capturing only once playback is underway.
      def frames_ready? : Bool
        !@src_frames.nil?
      end

      # Whether this backend's pixels are *visible to the terminal* and so must
      # be composited into a capture (`Crysterm::Capture`). False here: `Cells`
      # already lives in the window's cell buffer (captured for free), while
      # `External`/`Tek` are painted by an external program or separate window
      # the terminal can't see. `Media::Graphics` overrides this to true.
      def capture_pixels? : Bool
        false
      end

      # The current frame as a capture layer: an RGBA `PNGGIF::Bitmap` sized to
      # the widget's content cell-box × (*font_w* × *font_h*) pixels, plus the
      # content's top-left cell coordinates `{bmp, cell_xi, cell_yi}`. `nil` by
      # default; `Media::Graphics` overrides.
      def capture_layer(font_w : Int32, font_h : Int32) : Tuple(PNGGIF::Bitmap, Int32, Int32)?
        nil
      end

      # Starts (or resumes) animation playback. Source frames are composited once
      # (capped resolution, in a background fiber so a large GIF doesn't block
      # first paint); the loop then advances the frame index and re-renders.
      def play
        return if @playing
        # Replaying a finite animation that ran to completion: rewind to the
        # first frame. Without this the loop would start already at the last
        # frame and immediately re-complete, only flashing that frame. `#pause`
        # keeps `@anim_index` for resume, so gate on the completion flag rather
        # than the index value.
        if @finished
          @anim_index = 0
          @finished = false
        end
        png = source # (re)opens the streaming decoder when applicable
        return unless png

        # Only a *genuine* animation plays: a live video stream (`@stream`), or a
        # decoded source with more than one frame. A single-frame source is a
        # still — notably one injected via `#bitmap=`, whose `frames` is non-nil
        # unlike a decoded still's. Without this guard, auto-play on such a
        # source (e.g. `Graph::Canvas`'s `#ensure_animation`, which plays any
        # source with non-nil `frames`) would spin a one-frame loop re-rendering
        # forever at the minimum interval.
        return unless @stream || ((fr = png.frames) && fr.size > 1)

        @playing = true

        if @stream
          # Streaming video: pull frames into a single reused slot. Grouped on a
          # shared clock (`animate: timer`), the clock pulls one frame per tick
          # in lockstep; otherwise a private fiber pulls at the video's own rate.
          @src_frames = nil
          if @clock
            subscribe_clock
          else
            # Capture a fresh generation for this loop; a superseding
            # play/pause/stop bumps `@stream_gen` so this fiber exits.
            spawn stream_loop((@stream_gen += 1))
          end
        elsif @src_frames
          start_playback
        else
          spawn do
            Fiber.yield # let the current layout paint before the heavy build
            sw, sh = Media::Fitting.source_size png
            frames = @src_frames = png.animation_cellmaps(sw, sh, 1.0)
            if frames && !frames.empty? && @playing
              start_playback
            else
              @playing = false
            end
          end
        end
      end

      # Begins advancing frames once `@src_frames` exists: drive from the shared
      # clock if given (`animate: timer`), else run a private `FrameClock`.
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
          # Mirror `#stream_loop`'s termination: a false return means EOF with a
          # failed restart (or playback stopped). Without honoring it, the shared
          # clock keeps calling `advance_stream` every tick — relaunching (and
          # killing) an ffmpeg per frame forever with `playing?` stuck true.
          unless advance_stream st
            @playing = false
            unsubscribe_clock
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

      # Frame clock: advance the frame index over time and trigger a render
      # (which samples the current frame to the current box). Honours `speed`
      # and the image's loop count (`num_plays`; 0 = loop forever). Each tick
      # sets the next sleep to that frame's own delay, so GIFs keep their
      # variable per-frame timing.
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
        # request the render and set the interval from the frame actually being
        # displayed — so each frame is shown for its OWN delay, including frame 0.
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

      # Background fiber for a *streaming* video: pull the next frame from the
      # live ffmpeg decoder into a single reused `@src_frames` slot, drop the
      # backend's cache for it (`#invalidate_frame`), and re-render — constant
      # memory regardless of length. At end-of-stream the decoder restarts.
      # Honours `speed`; stops when `@playing` clears (`#stop` closes the pipe,
      # unblocking a pending read).
      private def stream_loop(gen : Int32)
        stream = @stream || return
        # Deadline-based pacing: decode + render takes real time, so a plain
        # `sleep(delay)` would drift the video slower than its true fps. Instead
        # advance a target deadline by the frame period and sleep only the
        # remainder, absorbing decode time into the period. If decode falls
        # behind, reset the deadline rather than burst-rendering to catch up.
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
          # Superseded, and our captured stream has been discarded (stop nilled
          # or a new play replaced `@stream`): close it to reap its ffmpeg.
          # Don't touch `@playing` — the loop that replaced us owns it now.
          stream.close
        end
      end

      # Pulls the next live frame from *stream* into the single reused
      # `@src_frames` slot, drops the backend's cached render for it
      # (`#invalidate_frame`), and re-renders. At end-of-stream the decoder
      # restarts. Returns false when the stream ended and couldn't be reopened
      # (or playback stopped), so the caller halts. Shared by the self-paced
      # `#stream_loop` and the shared-clock `#tick_frame`.
      private def advance_stream(stream) : Bool
        bmp = stream.next_frame
        if bmp.nil?
          return false unless @playing
          # Only loop a stream we still own. A superseded loop reaching EOF must
          # not `restart` a discarded stream — that relaunches an ffmpeg on an
          # object nothing owns (never closed/reaped). The loop's post-check
          # closes our captured stream instead.
          return false unless stream.same?(@stream)
          # Latch a permanently failed restart so no playback path retries a dead
          # source every frame (file deleted/moved/truncated mid-playback). `#source`
          # then returns nil, so a later `#play` won't respawn ffmpeg either.
          unless stream.restart # loop the video; bail if it won't reopen
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
      # stale cache entry for *idx*. No-op by default; cell/graphics families
      # override it.
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
    # The unified `fit` knob is advisory here: each helper has its own richer
    # scaling control — `Media::Overlay#stretch`/`#center`,
    # `Media::Ueberzug#scaler` — which actually takes effect.
    abstract class Media::External < Media::Base
      # External overlays are static; never auto-animate.
      @animate = false

      # Animation is not supported by an external-helper overlay.
      def play
        unsupported "animation"
      end

      # Displays *file*, replacing any image currently shown, and re-renders.
      # (`Media::Base#set_image` does the same but without the
      # `request_render`: the cell-grid/graphics backends already re-render
      # via their normal dirty/render path, but an external-overlay backend is
      # painted out-of-band by its `#redraw_image` hook, so showing a new
      # image needs an explicit kick.)
      def set_image(file : String)
        load file
        request_render
      end

      # Current cell rectangle (`{xi, yi, w, h}`) this widget should be
      # (re)painted at this frame, or `nil` if it shouldn't be painted at
      # all — hidden (directly or via an ancestor), detached, or with no
      # resolvable box yet. Shared redraw-geometry preamble for
      # `Media::Overlay`/`Media::Ueberzug#redraw_image`. Mirrors
      # `Media::Graphics#redraw_image`: a standalone `Rendered` listener must
      # not resolve `_get_coords(true)` against a hidden ancestor with no
      # rendered position (it would raise and kill the render fiber).
      protected def overlay_geometry : Tuple(Int32, Int32, Int32, Int32)?
        return unless visible_in_tree?
        window? || return
        pos = _get_coords(true) || return
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
    # Both register a single `Rendered` listener and tear it down on destroy,
    # with identical boilerplate for the listener-wrapper ivars and add/remove
    # dance, which lives here. Each backend supplies just the paint block and
    # any extra teardown (`Media::Tek` stops its animation loop, `Media::Ueberzug`
    # removes its placement). `Media::ScreenOverlay` documents why those two are
    # kept out of this module's lifecycle.
    module Media::RenderHook
      # Window the listener was registered on, kept so it can be removed on
      # destroy even after the widget is detached (`#window?` is nil).
      @listener_screen : ::Crysterm::Window?
      @ev_rendered : ::Crysterm::Event::Rendered::Wrapper?

      # Registers *block* to run after every window render on *s*, remembering
      # *s* and the wrapper so it can be removed later.
      protected def register_render_hook(s : ::Crysterm::Window, &block : ::Crysterm::Event::Rendered ->)
        @listener_screen = s
        @ev_rendered = s.on(::Crysterm::Event::Rendered, &block)
      end

      # Paint block captured for a detached construction, replayed once a window
      # is available (see `#register_render_hook_deferred`).
      @deferred_render_hook : (::Crysterm::Event::Rendered ->)?

      # Registers *block* now when a window is resolvable, else defers to a
      # one-shot `Attach`/`Reparent` hook. A backend built detached
      # (compose-then-attach, or a parent not yet on a `Window`) has no window at
      # construction, so calling the raising `window` accessor here would crash.
      protected def register_render_hook_deferred(&block : ::Crysterm::Event::Rendered ->)
        if s = window?
          register_render_hook(s, &block)
        else
          @deferred_render_hook = block
          on(::Crysterm::Event::Attach) { try_register_render_hook_deferred }
          on(::Crysterm::Event::Reparent) { try_register_render_hook_deferred }
        end
      end

      # Fires from the deferred hook: registers the captured block once a window
      # exists, guarded on `@listener_screen` so a re-attach doesn't double-register.
      private def try_register_render_hook_deferred
        return if @listener_screen
        s = window? || return
        blk = @deferred_render_hook || return
        register_render_hook(s, &blk)
        @deferred_render_hook = nil
      end

      # Removes the listener registered above and forgets the window.
      protected def teardown_render_hook
        s = @listener_screen || return
        @ev_rendered.try { |w| s.off ::Crysterm::Event::Rendered, w }
        @ev_rendered = nil
        @listener_screen = nil
      end
    end
  end
end
