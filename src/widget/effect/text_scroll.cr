require "../../widget_effect_direct"
require "../../colors"

module Crysterm
  class Widget
    module Effect
      # Shared substrate for the horizontally-looping rainbow text scrollers —
      # `Widget::Marquee` (flat, single-row) and `Effect::SineScroller` (the same
      # message composited across the full height on a sine wave).
      #
      # Both decompose the message into a `@chars` buffer once, loop it modulo its
      # own length (trailing spaces become the inter-repeat gap), advance one
      # column per `#step`, and optionally tint each glyph with a cycling hue.
      # This mixin owns that common machinery — the character buffer, the
      # scroll-index/glyph lookup, the rainbow hue properties and per-column
      # tint, the frame clock, and the self-driven animation loop (`Animated`).
      # The including widget keeps only its distinct `#render` compositing (and
      # its own `text=` repaint policy).
      module TextScroll
        # Self-driven frame loop (`start`/`stop`/`toggle`, `interval`, `running?`).
        # `#step` below supplies the per-frame state work; the including widget's
        # `#render` reads `@frame`.
        include Animated

        # The message scrolled across the widget. Reassigning it is safe at any
        # time; each widget defines its own `text=` (rebuilding `@chars`) since
        # they differ in repaint policy.
        getter text : String

        # `text` decomposed into its characters once, so the per-column paint can
        # index it in O(1). `String#[]` is O(n) for non-ASCII strings, which would
        # make a frame O(w·n); this cache is rebuilt only when `text` changes.
        @chars : Array(Char) = [] of Char

        # Direction the text travels (shared enum, defined on `Marquee`).
        property direction : Marquee::Direction = Marquee::Direction::Left

        # When true, each non-space glyph is tinted with a cycling hue instead of
        # the widget's foreground color.
        property? rainbow : Bool = false

        # Hue degrees added per column (the spatial rainbow spread) when `rainbow?`.
        property hue_spread : Int32 = 7

        # Hue degrees added per frame (the temporal cycling speed) when `rainbow?`.
        property hue_speed : Int32 = 8

        # Monotonically advancing frame counter. Int64 so it never wraps in any
        # realistic runtime; indexing uses a (sign-safe) modulo of `text.size`.
        @frame : Int64 = 0_i64

        # Advance one column. Painting happens in the including widget's `#render`
        # (state-only, like `CopperBar#step`), which reads `@frame` — so an
        # external master clock can call `step` then trigger a single render.
        def step
          @frame += 1
          mark_dirty # repaint under damage tracking
        end

        # The glyph shown in column *x* at frame *f* for a message of length *n*.
        # For `:left`, column x shows text[f + x] so the row shifts left as f
        # grows; `:right` shows text[x - f] so it shifts right (the same glyph
        # ordering, travelling the other way — not mirrored). Crystal's `%`
        # follows the divisor's sign, so the index is always valid.
        @[AlwaysInline]
        protected def scroll_glyph(f : Int64, x : Int32, n : Int32) : Char
          @chars[(direction.left? ? f + x : x - f) % n]
        end

        # The packed `0xRRGGBB` foreground for column *x* at frame *f* in rainbow
        # mode: the hue cycles across the columns (`hue_spread`) and over time
        # (`hue_speed`). `HSV_LUT[h]` is bit-identical to `hsv_i(h)`.
        @[AlwaysInline]
        protected def rainbow_fg(x : Int32, f : Int64) : Int64
          Attr.pack_color(Colors::HSV_LUT[(x * @hue_spread + f * @hue_speed) % 360])
        end
      end
    end
  end
end
