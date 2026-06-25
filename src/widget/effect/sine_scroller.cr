require "../box"
require "../marquee"
require "../../widget_effect_animated"
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
      # The glyphs are painted straight into the screen cells in `#render` —
      # each cell's color is set as a native `0xRRGGBB` attribute via `sattr` —
      # rather than by building a `{#rrggbb-fg}`-tagged content string and letting
      # the content pipeline re-tokenize it (`_parse_tags`) every frame. A
      # full-screen scroller emits one color run per column, so the tag reparse
      # was this widget's dominant per-frame cost; the direct path skips it
      # entirely. (This mirrors how `Widget::Gradient` paints its cells.)
      #
      # <!-- widget-examples:capture v1 -->
      # ![SineScroller screenshot](../../../examples/widget/effect/sine_scroller/sine_scroller-capture5s.apng)
      # <!-- /widget-examples:capture -->
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
        end

        # Advance one column. Painting happens in `#render` (state-only, like
        # `CopperBar#step`), which reads `@frame` — so an external master clock
        # calls `step` then triggers a single `screen.render`.
        def step
          @frame += 1
          mark_dirty # animation state changed; repaint under damage tracking
        end

        # Paints the looping message across the full height on a sine wave,
        # writing each glyph's cell directly with its native color. `_render`
        # (via `with_inner_coords`) establishes this frame's coordinates; the box
        # background is filled first (mirroring the spaces the old content string
        # carried), then the glyphs are laid over it.
        def render
          with_inner_coords do |xi, xl, yi, yl|
            w = xl - xi
            h = yl - yi
            next if w <= 0 || h <= 0

            # Background fill: the box's own colors, every cell (the field the
            # glyphs ride over).
            screen.fill_region(sattr(style), ' ', xi, xl, yi, yl)

            n = text.size
            next if n == 0

            f = @frame
            amp = (h - 1) / 2.0
            bg = style.bg
            fg_default = style.fg

            (0...w).each do |x|
              # Horizontal scroll, identical to `Marquee`: `:left` shifts the row
              # left as f grows, `:right` mirrors it. Crystal's `%` follows the
              # divisor's sign, so the index is always valid.
              idx = (direction.left? ? f + x : f - x) % n
              ch = text[idx]
              next if ch == ' '
              r = (amp * (1.0 + Math.sin(x * @wave_frequency + f * @wave_speed))).round.to_i.clamp(0, h - 1)
              fg = rainbow? ? Colors.hsv_i((x * @hue_spread + f * @hue_speed) % 360) : fg_default
              screen.fill_region(sattr(style, fg, bg), ch, xi + x, xi + x + 1, yi + r, yi + r + 1)
            end
          end
        end
      end
    end
  end
end
