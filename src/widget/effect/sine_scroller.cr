require "../box"
require "../marquee"
require "./animated"
require "../../colors"

module Crysterm
  class Widget
    module Effect
      # A sine-wave rainbow text scroller — the demoscene classic where a message
      # scrolls horizontally while each glyph rides up and down a sine wave, every
      # letter tinted its own cycling hue.
      #
      # Extracted from the `cracktro.cr` feature demo. It is the 2-D companion to
      # `Marquee`: the same horizontally-looping message (wrapping modulo its own
      # length, so trailing spaces become the gap), but composited across the
      # widget's whole height — each non-space glyph placed on the row given by
      # `sin(x * wave_frequency + frame * wave_speed)`. It reads its size lazily
      # each frame, so it tracks resize and `%`-relative sizing automatically.
      #
      # Like `Effect::Matrix` and `Marquee`, it drives its own animation: call
      # `#start` to spawn the render fiber and `#stop` to halt it. `#step` (which
      # only recomposes `content`; it does not render or sleep) is public so the
      # effect can instead be advanced from an external clock when several effects
      # must share one frame counter.
      #
      # ```
      # scroller = Widget::Effect::SineScroller.new parent: screen, top: 0, left: 0,
      #   width: "100%", height: 8, text: "GREETINGS TO EVERYONE   ...   "
      # scroller.start
      # ```
      #
      # NOTE: tag parsing is forced on (the rainbow path emits `{#rrggbb-fg}`
      # tags), so a literal `{` in `text` would be interpreted as a tag.
      class SineScroller < Box
        include Animated

        # The message scrolled across the widget. Reassigning it is safe at any time.
        property text : String

        # Direction the text travels (shared with `Marquee`).
        property direction : Marquee::Direction

        # Radians of the vertical wave added per column (its spatial frequency).
        property wave_frequency : Float64

        # Radians the wave advances per frame (how fast it undulates).
        property wave_speed : Float64

        # When true, each glyph carries its own cycling hue; otherwise the widget's
        # foreground color is used.
        property? rainbow : Bool

        # Hue degrees added per column (the spatial rainbow spread) when `rainbow?`.
        property hue_spread : Int32

        # Hue degrees added per frame (the temporal cycling speed) when `rainbow?`.
        property hue_speed : Int32

        # Monotonically advancing frame counter. Int64 so it never wraps in any
        # realistic runtime; indexing uses a (sign-safe) modulo of `text.size`.
        @frame : Int64 = 0

        def initialize(
          @text = "",
          @interval = 0.07.seconds,
          @direction : Marquee::Direction = :left,
          @wave_frequency = 0.32,
          @wave_speed = 0.22,
          @rainbow = true,
          @hue_spread = 7,
          @hue_speed = 6,
          **box,
        )
          super **box
          # The rainbow path emits `{#rrggbb-fg}` tags, so tag parsing must be on
          # regardless of what the caller passed.
          self.parse_tags = true
        end

        # Builds one frame: the looping message laid across the full height on a
        # sine wave, then advances by one column.
        def step
          w = awidth
          h = aheight
          n = text.size
          return if w <= 0 || h <= 0 || n == 0

          f = @frame
          amp = (h - 1) / 2.0
          grid = Array.new(h) { Array(String?).new(w, nil) }

          (0...w).each do |x|
            # Horizontal scroll, identical to `Marquee`: `:left` shifts the row
            # left as f grows, `:right` mirrors it. Crystal's `%` follows the
            # divisor's sign, so the index is always valid.
            idx = (direction.left? ? f + x : f - x) % n
            ch = text[idx]
            next if ch == ' '
            r = (amp * (1.0 + Math.sin(x * @wave_frequency + f * @wave_speed))).round.to_i.clamp(0, h - 1)
            grid[r][x] =
              if rainbow?
                "{#{Colors.hsv((x * @hue_spread + f * @hue_speed) % 360)}-fg}#{ch}{/}"
              else
                ch.to_s
              end
          end

          self.content = (0...h).map { |row|
            String.build { |io| (0...w).each { |x| io << (grid[row][x] || " ") } }
          }.join('\n')

          @frame += 1
        end
      end
    end
  end
end
