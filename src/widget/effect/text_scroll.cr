require "../../widget_effect_direct"
require "../../colors"

module Crysterm
  class Widget
    module Effect
      # Shared substrate for the horizontally-looping rainbow text scrollers.
      #
      # The message is decomposed into a `@chars` buffer once, alongside a
      # column→glyph table (`#rebuild_scroll_columns`) so the per-column paint
      # loop advances one *display* column per step rather than one codepoint —
      # a wide (CJK/emoji) glyph occupies 2 adjacent columns like it does
      # everywhere else in the rendering pipeline, instead of colliding with
      # its neighbor. The table loops modulo its own display width (trailing
      # spaces become the inter-repeat gap), advancing one column per `#step`,
      # optionally tinting each glyph with a cycling hue. The including widget
      # supplies its own `#render` compositing (via `#scroll_column`) and
      # `text=` repaint policy.
      module TextScroll
        # Self-driven frame loop (`start`/`stop`/`toggle`, `interval`, `running?`).
        include Animated

        # The message scrolled across the widget. Reassigning it is safe at any
        # time; each widget defines its own `text=` (rebuilding `@chars`) since
        # they differ in repaint policy.
        getter text : String

        # `text` decomposed into its characters once, so the per-column paint can
        # index it in O(1). `String#[]` is O(n) for non-ASCII strings, which would
        # make a frame O(w·n); this cache is rebuilt only when `text` changes.
        # Zero-width (combining) chars are dropped when rebuilt via
        # `#rebuild_scroll_columns` — see its doc.
        @chars : Array(Char) = [] of Char

        # Display width (1 or 2 columns) of each entry in `@chars`, parallel to
        # it. Built by `#rebuild_scroll_columns`.
        @widths : Array(Int32) = [] of Int32

        # Column (display-cell, not codepoint) → `@chars` index, and column →
        # offset-within-glyph (`0` = lead, `1` = the continuation column of a
        # wide glyph). Together these let the per-column paint loop advance one
        # *display* column per step instead of one codepoint, so a wide glyph
        # consumes 2 adjacent columns like it does everywhere else in the
        # rendering pipeline. Built by `#rebuild_scroll_columns`.
        @col_glyph : Array(Int32) = [] of Int32
        @col_offset : Array(Int32) = [] of Int32

        # Total display width of the looping message (`@col_glyph.size`) — the
        # modulus the per-column paint loop wraps against, in place of the
        # codepoint-counting `text.size`.
        @scroll_width : Int32 = 0

        # Direction the text travels.
        property direction : Marquee::Direction = Marquee::Direction::Left

        # When true, each non-space glyph is tinted with a cycling hue instead of
        # the widget's foreground color.
        property? rainbow : Bool = false

        # Hue degrees added per column (the spatial rainbow spread) when `rainbow?`.
        property hue_spread : Int32 = 7

        # Hue degrees added per frame (the temporal cycling speed) when `rainbow?`.
        property hue_speed : Int32 = 8

        # Monotonically advancing frame counter. Int64 so it never wraps in any
        # realistic runtime; indexing uses a (sign-safe) modulo of `@scroll_width`.
        @frame : Int64 = 0_i64

        # Advance one column. State only — painting happens in the including
        # widget's `#render`, so an external master clock can call `step` and then
        # trigger a single render.
        def step
          @frame += 1
          mark_dirty
        end

        # Rebuilds `@chars`/`@widths` and the display-column table from *text*.
        # Each includer's `text=` (and `initialize`, after `super` so
        # `full_unicode?` can resolve through an already-attached `parent:`)
        # calls this instead of the old bare `@text.chars`.
        #
        # Combining marks are 0 display columns wide; a column→glyph map has no
        # column to route them through, so they're dropped here rather than
        # left to desync the column count against the codepoint count (the
        # minimum fix — the full fix would keep them attached to their base
        # glyph via grapheme clustering, matching the content pipeline).
        protected def rebuild_scroll_columns(text : String) : Nil
          fu = full_unicode?
          chars = [] of Char
          widths = [] of Int32
          text.each_char do |ch|
            w = fu ? Unicode.width(ch) : 1
            next if w == 0
            chars << ch
            widths << w
          end
          col_glyph = Array(Int32).new
          col_offset = Array(Int32).new
          chars.each_index do |i|
            widths[i].times { |o| col_glyph << i; col_offset << o }
          end
          @chars = chars
          @widths = widths
          @col_glyph = col_glyph
          @col_offset = col_offset
          @scroll_width = col_glyph.size
        end

        # The glyph, its display width, and its offset-within-glyph (`0` = lead,
        # `1` = continuation column of a wide glyph) shown in display-column *x*
        # at frame *f*. For `:left`, column x shows the message shifted left as
        # f grows; `:right` shifts right (the same glyph ordering, travelling
        # the other way — not mirrored). Crystal's `%` follows the divisor's
        # sign, so the index is always valid. Callers must guard `@scroll_width
        # == 0` (empty message) before calling.
        @[AlwaysInline]
        protected def scroll_column(f : Int64, x : Int32) : {Char, Int32, Int32}
          i = (direction.left? ? f + x : -f + x) % @scroll_width
          gi = @col_glyph[i]
          {@chars[gi], @widths[gi], @col_offset[i]}
        end

        # The packed `0xRRGGBB` foreground for column *x* at frame *f* in rainbow
        # mode: the hue cycles across the columns (`hue_spread`) and over time
        # (`hue_speed`). `HSV_LUT[h]` is bit-identical to `hsv_i(h)`.
        @[AlwaysInline]
        protected def rainbow_fg(x : Int32, f : Int64) : Int64
          Attr.pack_color(Colors::HSV_LUT[((f * @hue_speed + x * @hue_spread) % 360).to_i32])
        end
      end
    end
  end
end
