require "../media"
require "../box"

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

      # Composited animation source frames (`{bitmap, delay_ms}`), built once.
      @src_frames : Array(Tuple(PNGGIF::Bitmap, Int32))? = nil

      # Whether playback is wanted. Stays the single source of truth: every place
      # that sets it false ends the loop, since the frame clock checks it each tick.
      @playing = false

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

      # Clears the loaded image and stops any animation. Subclasses override to
      # also drop their own caches, calling `super` to run this base cleanup.
      def clear_image
        stop
        @file = nil
        @source = nil
        @src_frames = nil
        @anim_index = 0
      end

      # The decoded source image (cached), or `nil` if none/failed to load.
      protected def source : PNGGIF::PNG?
        if s = @source
          return s
        end
        file = @file || return nil
        @source = Media.decode file
      end

      # Whether the composited source frames have been built yet (the heavy
      # decode/composite happens in a background fiber on first `#play`). Useful to
      # a recorder that wants to start capturing only once playback is underway.
      def frames_ready? : Bool
        !@src_frames.nil?
      end

      # Starts (or resumes) animation playback. Source frames are composited once
      # (capped resolution, in a background fiber so a large GIF doesn't block
      # first paint); the loop then advances the frame index and re-renders.
      def play
        return if @playing
        png = source
        return unless png
        @playing = true

        if @src_frames
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

      # Subscribe to the shared clock; each tick advances this widget's frame.
      # Idempotent — drops any prior subscription first.
      private def subscribe_clock : Nil
        c = @clock || return
        unsubscribe_clock
        @clock_sub = c.on(::Crysterm::Event::Tick) { advance_shared }
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

      # Pauses animation playback on the current frame.
      def pause
        @playing = false
        @animation.try &.stop
        unsubscribe_clock
      end

      # Stops animation playback and resets to the first frame.
      def stop
        @playing = false
        @animation.try &.stop
        unsubscribe_clock
        @anim_index = 0
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

      # Called by a backend when asked to do something it can't. Consults the
      # `image.unsupported` config option: `"error"` raises `UnsupportedError`,
      # anything else ignores it (the backend does what it can).
      protected def unsupported(feature : String) : Nil
        if Crysterm::Config.media_unsupported == "error"
          raise Media::UnsupportedError.new("#{self.class.name}: #{feature} is not supported by this image backend")
        end
      end
    end
  end
end
