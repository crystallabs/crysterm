require "../box"
require "../marquee"
require "../../widget_effect_direct"
require "../../colors"

module Crysterm
  class Widget
    module Effect
      # A sine-wave rainbow text scroller — a message scrolls horizontally while
      # each glyph rides up and down a sine wave, tinted its own cycling hue.
      #
      # The 2-D companion to `Marquee`: the same horizontally-looping message
      # (wrapping modulo its own length, so trailing spaces become the gap), but
      # composited across the widget's whole height — each non-space glyph placed
      # on the row given by `sin(x * wave_frequency + frame * wave_speed)`. Reads
      # its size lazily each frame, so it tracks resize and `%`-relative sizing
      # automatically.
      #
      # Drives its own animation: `#start` spawns the render fiber, `#stop` halts
      # it. `#step` (state only, no render/sleep) is public so the effect can be
      # advanced from an external clock shared by several effects.
      #
      # ```
      # scroller = Widget::Effect::SineScroller.new parent: window, top: 0, left: 0,
      #   width: "100%", height: 8, text: "GREETINGS TO EVERYONE   ...   "
      # scroller.start
      # ```
      #
      # Glyphs are painted straight into the window cells in `#render`, each
      # cell's color set as a native `0xRRGGBB` attribute via `style_to_attr`, rather
      # than through a `{#rrggbb-fg}`-tagged content string re-tokenized every
      # frame. A full-window scroller emits one color run per column, which makes
      # that tag reparse the dominant per-frame cost; the direct path skips it.
      #
      # <!-- widget-examples:capture v1 -->
      # ![SineScroller screenshot](../../../tests/widget/effect/sine_scroller/sine_scroller.5s.apng)
      # <!-- /widget-examples:capture -->
      class SineScroller < Box
        include TextScroll

        def text=(@text : String)
          @chars = @text.chars
          mark_dirty
        end

        # Radians of the vertical wave added per column (its spatial frequency).
        property wave_frequency : Float64

        # Radians the wave advances per frame (how fast it undulates).
        property wave_speed : Float64

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
          @chars = @text.chars
          super **box
        end

        # Paints the looping message across the full height on a sine wave,
        # writing each glyph's cell directly with its native color. The box
        # background is filled first, then the glyphs are laid over it.
        def render
          with_inner_coords do |xi, xl, yi, yl|
            w = xl - xi
            h = yl - yi
            next if w <= 0 || h <= 0

            # The attr's invariant parts (flags + bg) are packed once per frame.
            # Only fg varies per column, so the per-column cost is a single
            # `Attr.with_fg` rather than a full `style_to_attr` rebuild on every cell.
            da = style_to_attr(style)
            deff = Attr.fg da # widget's own fg, for the non-rainbow case

            # Background fill: the field the glyphs ride over.
            window.fill_region(da, ' ', xi, xl, yi, yl)

            n = text.size
            next if n == 0

            f = @frame
            amp = (h - 1) / 2.0

            (0...w).each do |x|
              ch = scroll_glyph(f, x, n)
              next if ch == ' '
              r = (amp * (1.0 + Math.sin(x * @wave_frequency + f * @wave_speed))).round.to_i.clamp(0, h - 1)
              fgf = rainbow? ? rainbow_fg(x, f) : deff
              window.fill_region(Attr.with_fg(da, fgf), ch, xi + x, xi + x + 1, yi + r, yi + r + 1)
            end
          end
        end
      end
    end
  end
end
