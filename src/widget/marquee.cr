require "./box"
require "./effect/text_scroll"
require "../widget_effect_direct"
require "../colors"

module Crysterm
  class Widget
    # A horizontally scrolling line of text — a "marquee" / ticker.
    #
    # Every frame it recomposes its single visible row as the `awidth`-wide
    # window onto an endlessly looping message. The message wraps modulo its own
    # length, so any trailing spaces in `text` become the gap between repeats and
    # the loop is seamless. Size is read lazily each frame, so it tracks terminal
    # resize and `%`-relative widths automatically.
    #
    # It drives its own animation: call `#start` to spawn the render fiber and
    # `#stop` to halt it.
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
    # Glyphs are painted straight into the window cells in `#render`, each cell's
    # color set as a native `0xRRGGBB` attribute via `style_to_attr`. Building a
    # `{#rrggbb-fg}`-tagged content string instead would re-tokenize every frame.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Marquee screenshot](../../tests/widget/marquee/marquee.5s.apng)
    # <!-- /widget-examples:capture -->
    class Marquee < Box
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
        rebuild_scroll_columns @text
        mark_dirty
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
        super **box
        # After `super`, so `full_unicode?` (which resolves through `window?`)
        # sees an already-attached `parent:`. A box built detached and
        # attached later still measures with the codepoint fallback, same
        # caveat as DialogButtonBox#make_button.
        rebuild_scroll_columns @text
      end

      # Paints the `awidth`-wide window onto the looping message into the top
      # content row, writing each glyph's cell directly with its native color.
      def render(with_children = true)
        with_inner_coords(with_children) do |xi, xl, yi, yl|
          w = xl - xi
          h = yl - yi
          next if w <= 0 || h <= 0

          # The field the glyphs ride over, and the inter-glyph gaps.
          window.fill_region(style_to_attr(style), ' ', xi, xl, yi, yl)

          next if @scroll_width == 0

          f = @frame

          # Hoisted out of the column loop: in rainbow mode only the foreground
          # varies, so flags and bg are reused and just the fg is repacked per
          # column via `Attr.with_fg`.
          base = style_to_attr style, style.fg, style.bg

          (0...w).each do |x|
            ch, width, offset = scroll_column(f, x)
            # A continuation column was either already written by its lead
            # (the previous loop iteration) or, if the lead scrolled off the
            # left edge (x == 0 here), stays the background blank filled above.
            next if offset == 1
            next if ch == ' '
            attr = rainbow? ? Attr.with_fg(base, rainbow_fg(x, f)) : base
            if width == 2
              next if x + 1 >= w # right-edge straddle: half a glyph can't render
              window.put_wide(attr, ch, xi + x, yi)
            else
              window.fill_region(attr, ch, xi + x, xi + x + 1, yi, yi + 1)
            end
          end
        end
      end
    end
  end
end
