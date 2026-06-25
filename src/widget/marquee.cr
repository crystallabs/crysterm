require "./box"
require "../widget_effect_animated"
require "../colors"

module Crysterm
  class Widget
    # A horizontally scrolling line of text — a "marquee" / ticker.
    #
    # Extracted from the `cracktro.cr` feature demo's line scroller: every frame
    # it recomposes its single visible row as the `awidth`-wide window onto an
    # endlessly looping message. The message wraps modulo its own length, so any
    # trailing spaces in `text` become the gap between repeats and the loop is
    # seamless. It reads its size lazily each frame, so it tracks terminal resize
    # and `%`-relative widths automatically.
    #
    # Like `Effect::Matrix` and `Loading`, it drives its own animation: call
    # `#start` to spawn the render fiber and `#stop` to halt it.
    #
    # ```
    # ticker = Widget::Marquee.new parent: screen, top: 0, left: 0,
    #   width: "100%", height: 1, text: "BREAKING NEWS   ...   "
    # ticker.start
    # ```
    #
    # With `rainbow: true` each glyph carries its own hue, cycling across the
    # columns and over time — the classic demoscene color scroller.
    #
    # The glyphs are painted straight into the screen cells in `#render`, each
    # cell's color set as a native `0xRRGGBB` attribute via `sattr`, rather than
    # by building a `{#rrggbb-fg}`-tagged content string that the content pipeline
    # re-tokenizes (`_parse_tags`) every frame. (Mirrors `Effect::SineScroller`
    # and `Widget::Gradient`.)
    #
    # <!-- widget-examples:capture v1 -->
    # ![Marquee screenshot](../../examples/widget/marquee/marquee-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Marquee < Box
      # Self-driven frame loop (`start`/`stop`/`toggle`, `interval`, `running?`).
      # `#step` below supplies the per-frame work.
      include Effect::Animated

      # Scroll direction of the text.
      enum Direction
        # Text travels right-to-left (the classic marquee). The newest character
        # enters at the right edge.
        Left
        # Text travels left-to-right; the newest character enters at the left edge.
        Right
      end

      # The message scrolled across the widget. Reassigning it is safe at any time.
      property text : String

      # Direction the text travels.
      property direction : Direction

      # When true, each non-space glyph is tinted with a cycling hue instead of
      # the widget's foreground color.
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
        @direction : Direction = :left,
        @rainbow = false,
        @hue_spread = 7,
        @hue_speed = 8,
        **box,
      )
        super **box
      end

      # Advance one column. Painting happens in `#render` (state-only, like
      # `Effect::CopperBar#step`), which reads `@frame`.
      def step
        @frame += 1
        mark_dirty # animation state changed; repaint under damage tracking
      end

      # Paints the `awidth`-wide window onto the looping message into the top
      # content row, writing each glyph's cell directly with its native color.
      # `_render` (via `with_inner_coords`) establishes this frame's coordinates;
      # the box background is filled first, then the glyphs are laid over it.
      def render
        with_inner_coords do |xi, xl, yi, yl|
          w = xl - xi
          h = yl - yi
          next if w <= 0 || h <= 0

          # Background fill: the box's own colors (the field the glyphs ride over,
          # and the inter-glyph gaps/spaces).
          screen.fill_region(sattr(style), ' ', xi, xl, yi, yl)

          n = text.size
          next if n == 0

          f = @frame
          bg = style.bg
          fg_default = style.fg

          (0...w).each do |x|
            # For `:left`, column x shows text[f + x] so that as f grows the row
            # shifts left; `:right` is the mirror. Crystal's `%` follows the
            # divisor's sign, so the index is always valid.
            idx = (direction.left? ? f + x : f - x) % n
            ch = text[idx]
            next if ch == ' '
            fg = rainbow? ? Colors.hsv_i((x * @hue_spread + f * @hue_speed) % 360) : fg_default
            screen.fill_region(sattr(style, fg, bg), ch, xi + x, xi + x + 1, yi, yi + 1)
          end
        end
      end
    end
  end
end
