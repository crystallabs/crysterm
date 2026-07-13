require "./box"
require "./effect/text_scroll"
require "../widget_effect_direct"
require "../colors"

module Crysterm
  class Widget
    # A horizontally scrolling line of text — a "marquee" / ticker.
    #
    # Extracted from the `cracktro.cr` feature demo's line scroller: every frame
    # it recomposes its single visible row as the `awidth`-wide window onto an
    # endlessly looping message. The message wraps modulo its own length, so any
    # trailing spaces in `text` become the gap between repeats and the loop is
    # seamless. Reads its size lazily each frame, so it tracks terminal resize
    # and `%`-relative widths automatically.
    #
    # Like `Effect::Matrix` and `Loading`, it drives its own animation: call
    # `#start` to spawn the render fiber and `#stop` to halt it.
    #
    # ```
    # ticker = Widget::Marquee.new parent: window, top: 0, left: 0,
    #   width: "100%", height: 1, text: "BREAKING NEWS   ...   "
    # ticker.start
    # ```
    #
    # With `rainbow: true` each glyph carries its own hue, cycling across the
    # columns and over time — the classic demoscene color scroller.
    #
    # Glyphs are painted straight into the window cells in `#render`, each
    # cell's color set as a native `0xRRGGBB` attribute via `sattr`, rather than
    # building a `{#rrggbb-fg}`-tagged content string re-tokenized (`_parse_tags`)
    # every frame. (Mirrors `Effect::SineScroller` and `Widget::Gradient`.)
    #
    # <!-- widget-examples:capture v1 -->
    # ![Marquee screenshot](../../tests/widget/marquee/marquee.5s.apng)
    # <!-- /widget-examples:capture -->
    class Marquee < Box
      # The scroller substrate shared with `Effect::SineScroller`: the `@chars`
      # buffer, the `text`/`direction`/rainbow-hue properties, the `@frame` clock,
      # `#step`, `#scroll_glyph`/`#rainbow_fg`, and the self-driven animation loop.
      include Effect::TextScroll

      # Scroll direction of the text.
      enum Direction
        # Text travels right-to-left (the classic marquee). The newest character
        # enters at the right edge.
        Left
        # Text travels left-to-right; the newest character enters at the left edge.
        Right
      end

      def text=(@text : String)
        @chars = @text.chars
      end

      def initialize(
        @text = "",
        @interval = 0.07.seconds,
        @direction : Direction = :left,
        @rainbow = false,
        @hue_spread = 7,
        @hue_speed = 8,
        **box,
      )
        @chars = @text.chars
        super **box
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

          # Background fill: the field the glyphs ride over and the inter-glyph gaps.
          window.fill_region(sattr(style), ' ', xi, xl, yi, yl)

          n = text.size
          next if n == 0

          f = @frame

          # Per-frame invariants hoisted out of the column loop. `base` is the
          # plain glyph attr, used as-is outside rainbow mode; in rainbow mode
          # only the foreground varies, so flags and bg (and Opaque alpha) are
          # reused and just the fg is repacked per column via `Attr.with_fg`.
          base = sattr style, style.fg, style.bg

          (0...w).each do |x|
            ch = scroll_glyph(f, x, n)
            next if ch == ' '
            attr = rainbow? ? Attr.with_fg(base, rainbow_fg(x, f)) : base
            window.fill_region(attr, ch, xi + x, xi + x + 1, yi, yi + 1)
          end
        end
      end
    end
  end
end
