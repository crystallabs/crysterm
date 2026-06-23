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

      # Composited animation source frames (`{bitmap, delay_ms}`). For an eager
      # image/video this is the full frame list, built once; for a *streaming*
      # video it is a single reused slot holding the current frame (see
      # `#stream_loop`).
      @src_frames : Array(Tuple(PNGGIF::Bitmap, Int32))? = nil
      @playing = false

      # Live streaming video decoder (Tier 2), when the source is a video resolved
      # to `VideoSource::Mode::Stream`; `nil` for eager image/video sources.
      @stream : Media::VideoSource::Stream? = nil

      # Set once a source has failed to load, so `#source` returns `nil` without
      # re-attempting (re-opening ffmpeg) on every render. Reset when a new file
      # is loaded.
      @load_failed = false

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

      # Starts (or resumes) animation playback. Source frames are composited once
      # (capped resolution, in a background fiber so a large GIF doesn't block
      # first paint); the loop then advances the frame index and re-renders.
      def play
        return if @playing
        png = source # (re)opens the streaming decoder when applicable
        return unless png
        @playing = true

        if @stream
          # Streaming video: the loop pulls frames into a single reused slot.
          @src_frames = nil
          spawn stream_loop
        elsif @src_frames
          spawn animate_loop
        else
          spawn do
            Fiber.yield # let the current layout paint before the heavy build
            sw, sh = Media::Fitting.source_size png
            frames = @src_frames = png.animation_cellmaps(sw, sh, 1.0)
            if frames && !frames.empty? && @playing
              animate_loop
            else
              @playing = false
            end
          end
        end
      end

      # Pauses animation playback on the current frame. A streaming decoder is
      # left open (ffmpeg blocks on the full pipe) so `#play` resumes promptly.
      def pause
        @playing = false
      end

      # Stops animation playback and resets to the first frame. A streaming
      # decoder is closed and dropped (reaping ffmpeg); the next `#play`
      # re-opens it from the beginning via `#source`.
      def stop
        @playing = false
        @anim_index = 0
        if st = @stream
          @stream = nil
          @source = nil # force `#source` to re-open the stream on next play
          st.close
        end
      end

      # Background fiber: advance the frame index over time and trigger a render
      # (which samples the current frame to the current box). Honours `speed` and
      # the image's loop count (`num_plays`; 0 = loop forever).
      private def animate_loop
        src = @src_frames
        return unless src
        png = source
        num_plays = png ? png.num_plays : 0
        plays = 0
        while @playing
          request_render

          delay = src[@anim_index]?.try(&.[1]) || 100
          @anim_index += 1
          if @anim_index >= src.size
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
          bmp = stream.next_frame
          if bmp.nil?
            break unless @playing
            stream.restart || break # loop the video; bail if it won't reopen
            bmp = stream.next_frame || break
          end
          delay = stream.delay
          slot = (@src_frames ||= [{bmp, delay}])
          slot[0] = {bmp, delay}
          @anim_index = 0
          invalidate_frame 0 # the slot's content changed; drop any cached render
          request_render

          ms = delay / @speed
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

      # Hook: a backend caches per-frame renders keyed by frame index; streaming
      # reuses index 0 with changing content, so the loop calls this to drop the
      # stale cache entry for *idx* before re-rendering. No-op by default; the
      # cell and graphics families override it.
      protected def invalidate_frame(idx : Int32)
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
