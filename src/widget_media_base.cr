require "./widget/media"
require "./widget/box"

module Crysterm
  class Widget
    # Raised by an image backend asked for a feature it can't provide, when the
    # `image.unsupported` config option is `"error"` (see `Media::Base#unsupported`).
    class Media::UnsupportedError < Exception
    end

    # Common abstract base for every `Widget::Media` backend. It formalizes the
    # backend *contract* (image source, fit, animation) so all backends behave
    # the same way and the factory (`Widget::Media.new`) can return one type
    # (`Media::Base`) instead of a union.
    #
    # Families specialize it further:
    #
    # * `Media::Cells` — the image becomes character cells Crysterm owns (`Ansi`, `Glyph`).
    # * `Media::External` — an external helper paints the pixels (`Overlay`, `Ueberzug`).
    # * `Media::Graphics` — the terminal renders in-band escapes (`Sixel`, `Regis`, `Kitty`, `Iterm`).
    # * `Media::Tek` — a separate Tektronix window.
    #
    # Animation is **render-driven** here: `#play` composites the source frames
    # once (in a fiber) and a loop advances `#anim_index` + calls `request_render`
    # at each frame's delay; the backend samples the current frame in its own
    # `#render`. Backends whose terminal animates for them (iTerm2) or which can't
    # animate at all (the external/static ones) opt out — the latter route
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

      # The image decoded once at native resolution (the resolution-independent
      # source), via the process-wide `Media.decode` cache.
      @source : PNGGIF::PNG? = nil

      # Composited animation source frames (`{bitmap, delay_ms}`). For an eager
      # image/video this is the full frame list, built once; for a *streaming*
      # video it is a single reused slot holding the current frame (see
      # `#stream_loop`).
      @src_frames : Array(Tuple(PNGGIF::Bitmap, Int32))? = nil

      # Whether playback is wanted. Stays the single source of truth: every place
      # that sets it false ends the loop, since the frame clock checks it each tick.
      getter? playing = false

      # The private frame clock advancing `#anim_index` over time, used for solo
      # playback (`animate: true`); nil when not playing or when driven by a
      # shared clock instead.
      @animation : Animation? = nil

      # A shared frame clock (a `Timer`) when the widget was created with
      # `animate: someTimer`. While set, playback advances one frame per tick of
      # that clock — in lockstep with every other media widget on the same clock —
      # rather than running its own `@animation`. The clock is owned by the caller,
      # so the widget only subscribes/unsubscribes, never starts or stops it.
      @clock : Timer? = nil

      # This widget's subscription to `@clock`, kept so it can unsubscribe on
      # pause/stop/destroy (and not leave the shared clock poking a dead widget).
      @clock_sub : ::Crysterm::Event::Tick::Wrapper? = nil

      # Live streaming video decoder (Tier 2), when the source is a video resolved
      # to `VideoSource::Mode::Stream`; `nil` for eager image/video sources.
      @stream : Media::VideoSource::Stream? = nil

      # Set once a source has failed to load, so `#source` returns `nil` without
      # re-attempting (re-opening ffmpeg) on every render. Reset when a new file
      # is loaded.
      @load_failed = false

      # Resolves the `animate:` constructor argument. `true`/`false` toggle whether
      # an animated source plays; a `Timer` enables playback *and* drives it from
      # that shared clock, so several widgets given the same clock stay in sync.
      protected def setup_animate(animate : Bool | Timer) : Nil
        case animate
        in Timer
          @animate = true
          @clock = animate
        in Bool
          @animate = animate
        end
      end

      # Index of the frame currently shown. The animation loop advances it, but it
      # can also be set directly (after `#pause`) to drive playback from an
      # external clock — e.g. to keep several images in lockstep.
      property anim_index : Int32 = 0

      # Loads *file* (decodes lazily via `#source`); the canonical implementation
      # each backend provides. `#set_image` is an alias.
      abstract def load(file : String)

      # Alias for `#load`, for API parity across backends.
      def set_image(file : String)
        load file
      end

      # Sets the backend's source directly from an in-memory RGBA bitmap, instead
      # of decoding a file. Wraps it as a single-frame `PNGGIF::PNG` so the whole
      # existing sample/compose/render pipeline (every backend family) renders it
      # unchanged. This is the entry point `Graph::Canvas` uses to display a
      # freshly painted frame; it clears any per-size sample cache so a live,
      # same-size update re-renders. The bitmap must be non-empty.
      def bitmap=(bmp : PNGGIF::Bitmap) : PNGGIF::Bitmap
        h = bmp.size
        w = h > 0 ? bmp[0].size : 0
        raise ArgumentError.new("Media#bitmap=: empty bitmap") if w <= 0 || h <= 0
        @file = nil
        @load_failed = false
        @src_frames = nil
        @source = PNGGIF::PNG.from_frames([{bmp, 0}], w, h)
        reset_sample_cache
        bmp
      end

      # The backend's native pixel resolution for a *cols*×*rows* content box —
      # the size `Graph::Canvas` should allocate its bitmap at so this backend
      # renders it crisply (no resampling). Default is one pixel per cell; the
      # sub-cell (`Glyph`) and true-pixel (`Graphics`) families override it.
      def native_resolution(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        {cols, rows}
      end

      # Physical width:height of one of this backend's device pixels (1.0 = square),
      # for `Graph::Painter#pixel_aspect` so circles stay round. Default assumes a
      # ~1:2 cell (one pixel per cell). Overridden by `Glyph` (sub-cell) and
      # `Graphics` (true square pixels).
      def native_pixel_aspect : Float64
        0.5
      end

      # Hook: drop any cached per-size sample so the next render re-derives it from
      # the (newly set) source. No-op here; `Media::Cells` overrides it.
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
        @load_failed = false
      end

      # The decoded source image (cached), or `nil` if none/failed to load. For a
      # streaming video this opens the live decoder and returns its 1-frame
      # resampling vehicle (`@stream` then drives playback); otherwise it decodes
      # eagerly via the process-wide `Media.decode` cache. A failed open is not
      # retried (see `@load_failed`).
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

      # Whether the composited source frames have been built yet (the heavy
      # decode/composite happens in a background fiber on first `#play`). Useful to
      # a recorder that wants to start capturing only once playback is underway.
      def frames_ready? : Bool
        !@src_frames.nil?
      end

      # Whether this backend's pixels are *visible to the terminal* and so must be
      # composited into a capture (`Crysterm::Capture`). False here: the
      # `Cells` family already lives in the screen's cell buffer (captured for
      # free), while `External`/`Tek` are painted by an external program or a
      # separate window the terminal can't see. The in-band terminal-graphics
      # family (`Media::Graphics`: sixel/kitty/iterm/regis) overrides this to true.
      def capture_pixels? : Bool
        false
      end

      # The current frame as a capture layer: an RGBA `PNGGIF::Bitmap` sized to
      # the widget's content cell-box × (*font_w* × *font_h*) pixels, plus the
      # content's top-left cell coordinates `{bmp, cell_xi, cell_yi}`. `nil` when
      # this backend contributes nothing (the default; `Media::Graphics` overrides).
      def capture_layer(font_w : Int32, font_h : Int32) : Tuple(PNGGIF::Bitmap, Int32, Int32)?
        nil
      end

      # Starts (or resumes) animation playback. Source frames are composited once
      # (capped resolution, in a background fiber so a large GIF doesn't block
      # first paint); the loop then advances the frame index and re-renders.
      def play
        return if @playing
        png = source # (re)opens the streaming decoder when applicable
        return unless png

        # Only a *genuine* animation plays: a live video stream (`@stream`), or a
        # decoded source with more than one frame. A single-frame source is a
        # still — notably one injected via `#bitmap=`, which wraps the frame as a
        # `PNGGIF::PNG` whose `frames` is non-nil (the frame-list constructor
        # always sets it, unlike a decoded still where it stays nil). Without this
        # guard, auto-play on such a source (e.g. a `Graph::Canvas` on a Sixel/
        # Kitty backend, whose `#ensure_animation` plays any source with non-nil
        # `frames`) would start a one-frame loop that re-renders forever at the
        # minimum interval — a CPU/redraw spin.
        return unless @stream || ((fr = png.frames) && fr.size > 1)

        @playing = true

        if @stream
          # Streaming video: pull frames into a single reused slot. When grouped
          # on a shared clock (`animate: timer`) the clock pulls one frame per
          # tick (in lockstep with the other widgets on it); otherwise a private
          # fiber pulls at the video's own frame rate.
          @src_frames = nil
          if @clock
            subscribe_clock
          else
            spawn stream_loop
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
      # clock if one was given (`animate: timer`), else run a private per-frame
      # `Animation`.
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

      # One shared-clock tick of playback: for a streaming source pull and present
      # the next live frame, otherwise step the prebuilt frame index. Either way
      # all widgets on the same clock advance together, one frame per tick.
      private def tick_frame : Nil
        return unless @playing
        if st = @stream
          advance_stream st
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

      # One frame per shared-clock tick (wrapping). The shared clock's own cadence
      # sets the rate, so per-frame GIF delays are not honored in this mode — the
      # tradeoff for keeping several widgets in exact lockstep off one clock.
      private def advance_shared : Nil
        return unless @playing
        src = @src_frames
        return if src.nil? || src.empty?
        @anim_index = (@anim_index + 1) % src.size
        request_render
      end

      # Pauses animation playback on the current frame. A streaming decoder is
      # left open (ffmpeg blocks on the full pipe) so `#play` resumes promptly.
      def pause
        @playing = false
        @animation.try &.stop
        unsubscribe_clock
      end

      # Stops animation playback and resets to the first frame. A streaming
      # decoder is closed and dropped (reaping ffmpeg); the next `#play`
      # re-opens it from the beginning via `#source`.
      def stop
        @playing = false
        @animation.try &.stop
        unsubscribe_clock
        @anim_index = 0
        if st = @stream
          @stream = nil
          @source = nil # force `#source` to re-open the stream on next play
          st.close
        end
      end

      # Frame clock: advance the frame index over time and trigger a render (which
      # samples the current frame to the current box). Honours `speed` and the
      # image's loop count (`num_plays`; 0 = loop forever). Each tick shows the
      # current frame, then sets the next sleep to that frame's own delay (so GIFs
      # keep their variable per-frame timing).
      private def animate_loop
        src = @src_frames
        return unless src
        png = source
        num_plays = png ? png.num_plays : 0
        plays = 0

        # Fresh run: drop any previous clock so a rapid stop→play can't leave two
        # fibers advancing the same index.
        @animation.try &.stop
        @animation = Animation.new((src[@anim_index]?.try(&.[1]) || 100).milliseconds) do |clock|
          if @playing
            request_render

            delay = src[@anim_index]?.try(&.[1]) || 100
            @anim_index += 1
            if @anim_index >= src.size
              @anim_index = 0
              plays += 1
              @playing = false if num_plays > 0 && plays >= num_plays
            end

            ms = (delay / @speed).to_i
            ms = 1 if ms < 1
            clock.interval = ms.milliseconds # honor this frame's own delay
          end
          # End the clock once playback is no longer wanted, so any `@playing =
          # false` (pause/stop/num_plays) stops the loop on the next tick — exactly
          # as the old `while @playing` did.
          clock.stop unless @playing
        end
        @animation.try &.start
      end

      # Background fiber for a *streaming* video: pull the next frame from the
      # live ffmpeg decoder into a single reused `@src_frames` slot, drop the
      # backend's cache for it (`#invalidate_frame`), and re-render — at constant
      # memory regardless of length. At end-of-stream the decoder restarts (the
      # video loops). Honours `speed`; stops when `@playing` clears (a `#stop`
      # closes the pipe, unblocking a pending read).
      private def stream_loop
        stream = @stream || return
        # Deadline-based pacing: each frame's decode + render takes real time, so
        # a plain `sleep(delay)` would make the period `decode + delay` and the
        # video drift slower than its true fps. Instead advance a target deadline
        # by the frame period and sleep only the remainder, absorbing decode time
        # into the period. If decode falls behind the period, reset the deadline
        # (drop the deficit) rather than burst-rendering to catch up.
        next_at = Time.instant
        while @playing
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
        @playing = false
      end

      # Pulls the next live frame from *stream* into the single reused `@src_frames`
      # slot, drops the backend's cached render for it (`#invalidate_frame`), and
      # re-renders. At end-of-stream the decoder restarts (the video loops).
      # Returns false when the stream ended and could not be reopened (or playback
      # was stopped), so the caller halts. Shared by the self-paced `#stream_loop`
      # and the shared-clock `#tick_frame`, so grouped streams advance one frame
      # per clock tick.
      private def advance_stream(stream) : Bool
        bmp = stream.next_frame
        if bmp.nil?
          return false unless @playing
          stream.restart || return false # loop the video; bail if it won't reopen
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
      # stale cache entry for *idx* before re-rendering. No-op by default; the
      # cell and graphics families override it.
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
  end
end
