require "../image"
require "../box"

module Crysterm
  class Widget
    # Raised by an image backend asked for a feature it can't provide, when the
    # `image.unsupported` config option is `"error"` (see `Image::Base#unsupported`).
    class Image::UnsupportedError < Exception
    end

    # Common abstract base for every `Widget::Image` backend. It formalizes the
    # backend *contract* (image source, fit, animation) so all backends behave
    # the same way and the factory (`Widget::Image.new`) can return one type
    # (`Image::Base`) instead of a union.
    #
    # Families specialize it further:
    #
    # * `Image::Cells` — the image becomes character cells Crysterm owns (`Ansi`, `Glyph`).
    # * `Image::External` — an external helper paints the pixels (`Overlay`, `Ueberzug`).
    # * `Image::Graphics` — the terminal renders in-band escapes (`Sixel`, `Regis`, `Kitty`, `Iterm`).
    # * `Image::Tek` — a separate Tektronix window.
    #
    # Animation is **render-driven** here: `#play` composites the source frames
    # once (in a fiber) and a loop advances `#anim_index` + calls `request_render`
    # at each frame's delay; the backend samples the current frame in its own
    # `#render`. Backends whose terminal animates for them (iTerm2) or which can't
    # animate at all (the external/static ones) opt out — the latter route
    # `#play`/`#pause`/`#stop` through `#unsupported`.
    abstract class Image::Base < Box
      # Path (or `http(s)` URL) of the loaded image.
      property file : String? = nil

      # How a still image is fit into a box whose aspect differs (see `Image::Fit`).
      property fit : Image::Fit = Image::Fit::Stretch

      # Playback speed multiplier for animations (1.0 = native speed).
      property speed : Float64 = 1.0

      # Whether to play animated (GIF/APNG) sources automatically.
      property? animate : Bool = true

      # The image decoded once at native resolution (the resolution-independent
      # source), via the process-wide `Image.decode` cache.
      @source : PNGGIF::PNG? = nil

      # Composited animation source frames (`{bitmap, delay_ms}`), built once.
      @src_frames : Array(Tuple(PNGGIF::Bitmap, Int32))? = nil
      @playing = false

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
        @source = Image.decode file
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
          spawn animate_loop
        else
          spawn do
            Fiber.yield # let the current layout paint before the heavy build
            sw, sh = Image::Fitting.source_size png
            frames = @src_frames = png.animation_cellmaps(sw, sh, 1.0)
            if frames && !frames.empty? && @playing
              animate_loop
            else
              @playing = false
            end
          end
        end
      end

      # Pauses animation playback on the current frame.
      def pause
        @playing = false
      end

      # Stops animation playback and resets to the first frame.
      def stop
        @playing = false
        @anim_index = 0
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

      # Called by a backend when asked to do something it can't. Consults the
      # `image.unsupported` config option: `"error"` raises `UnsupportedError`,
      # anything else ignores it (the backend does what it can).
      protected def unsupported(feature : String) : Nil
        if Crysterm::Config.image_unsupported == "error"
          raise Image::UnsupportedError.new("#{self.class.name}: #{feature} is not supported by this image backend")
        end
      end
    end
  end
end
