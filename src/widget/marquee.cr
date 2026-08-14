require "./box"
require "./effect/text_scroll"
require "./effect/animated"
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
    # Glyphs are painted straight into the window cells in `#paint`, each cell's
    # color set as a native `0xRRGGBB` attribute via `style_to_attr`. Building a
    # `{#rrggbb-fg}`-tagged content string instead would re-tokenize every frame.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Marquee screenshot](../../tests/widget/marquee/marquee.5s.apng)
    # <!-- /widget-examples:capture -->
    class Marquee < Box
      include Effect::TextScroll

      # Scroll direction of the text — the mixin's enum, aliased so existing
      # `Marquee::Direction` call sites keep working.
      alias Direction = Effect::TextScroll::Direction

      # `style_to_attr` memo for the per-frame render: the animation redraws
      # every interval with an unchanged style, so the attr derivation is
      # skipped until a style setter (or a cascade swap) invalidates it.
      @attr_memo = Style::AttrMemo.new

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
      def paint(with_children = true)
        with_inner_coords(with_children) do |xi, xl, yi, yl|
          w = xl - xi
          h = yl - yi
          next if w <= 0 || h <= 0

          # One memoized derivation serves both the background fill and the
          # per-glyph base: `style_to_attr(style, style.fg, style.bg)` packs
          # the identical attr as the plain form (see `Style::AttrMemo#fetch`).
          base = @attr_memo.fetch(style)

          # The field the glyphs ride over, and the inter-glyph gaps.
          window.fill_region(base, ' ', xi, xl, yi, yl)

          next if @scroll_width == 0

          f = @frame

          # Hoisted out of the column loop: in rainbow mode only the foreground
          # varies, so flags and bg are reused and just the fg is repacked per
          # column via `Attr.with_fg`.

          (0...w).each do |x|
            next unless glyph = visible_scroll_glyph(f, x)
            ch, width = glyph
            attr = rainbow? ? Attr.with_fg(base, rainbow_fg(x, f)) : base
            put_scroll_glyph(attr, ch, width, xi + x, yi, xl)
          end
        end
      end
    end
  end
end
