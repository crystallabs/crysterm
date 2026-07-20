require "./abstract_slider"

module Crysterm
  class Widget
    # Rotary value selector, modeled after Qt's `QDial`.
    #
    # Picks an integer `#value` within `[#minimum, #maximum]`; the value is shown
    # as a compass-style pointer that sweeps around as it changes (plus the number
    # itself when `#text_visible?`). Arrow keys / the mouse wheel rotate it by
    # `#step`, Page Up/Down by `#page_step`, and `#wrapping?` rolls over at the ends.
    # Emits `Event::ValueChanged` on every change.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Dial screenshot](../../tests/widget/dial/dial.5s.apng)
    # <!-- /widget-examples:capture -->
    class Dial < AbstractSlider
      property? text_visible : Bool = true

      # Default pointer glyphs for the eight compass directions, starting at
      # "north" and going clockwise. Resolution goes through `#pointer_ring`.
      POINTERS = ['↑', '↗', '→', '↘', '↓', '↙', '←', '↖']

      def initialize(
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @step = 1,
        @page_step = 10,
        wrapping = false,
        @text_visible = true,
        **input,
      )
        super **{keys: true}.merge(input)

        @wrapping = wrapping
        # Guarded range+value init: never store an inverted range, which would
        # leave `#value` stuck after `clamp`.
        init_range @minimum, @maximum, value

        handle Crysterm::Event::KeyPress

        on(Crysterm::Event::Mouse) do |e|
          ranged_wheel e
        end
      end

      # The pointer ring cycled by `#pointer`: CSS `Dial { glyphs: "…" }` (each
      # character one clockwise step from "north"), else the registry's
      # `DialPointers` at the effective tier. Memoized — `#pointer` runs per render.
      private def pointer_ring : Array(Char)
        key = glyph_key(style)
        if (r = @_ring) && @_ring_key == key
          return r
        end
        @_ring_key = key
        @_ring = glyph_seq(Glyphs::SeqRole::DialPointers, style)
      end

      # :ditto:
      @_ring : Array(Char)?
      @_ring_key : {String?, Glyphs::Tier, UInt64}?

      # The pointer glyph for the current value (one of the `#pointer_ring`
      # steps, mapping the value's position in the range onto a clockwise angle).
      private def pointer : Char
        ring = pointer_ring
        s = value_span
        frac = s == 0 ? 0.0 : (@value.to_i64 - @minimum) / s.to_f
        # A wrapping dial maps the range onto the full circle, so the maximum
        # rolls back onto the minimum's "north". A non-wrapping dial spreads the
        # range across the arc instead, landing the maximum on the last glyph.
        steps = wrapping? ? ring.size : ring.size - 1
        ring[(frac * steps).round.to_i % ring.size]
      end

      # Cached value strings (plain + focused-bracketed form), rebuilt only when
      # `@value` changes rather than per render.
      @value_plain : String = ""
      @value_bracketed : String = ""

      # Returns the value string for the current focus state, rebuilding the
      # cached pair only when `@value` changed since the last call.
      private def value_text : String
        if value_text_stale?
          @value_plain = @value.to_s
          @value_bracketed = "‹#{@value}›"
        end
        focused? ? @value_bracketed : @value_plain
      end

      def render(with_children = true)
        with_inner_coords(with_children) do |xi, xl, yi, yl|
          window.fill_region style_to_attr(style), style.fill_char, xi, xl, yi, yl

          # Pointer in the middle of the knob. When the value is shown it owns the
          # bottom row (`yl - 1`), so center the pointer in the rows above it
          # (`yi..yl-2`); otherwise the value text would overwrite and hide the
          # pointer on a short (inner height <= 2) dial.
          pointer_bottom = text_visible? ? Math.max(yi, yl - 2) : yl
          cx = xi + (xl - xi) // 2
          cy = yi + (pointer_bottom - yi) // 2
          window.fill_region style_to_attr(style.indicator), pointer, cx, cx + 1, cy, cy + 1

          # Draw the value on the reserved bottom row, but only when it does not
          # land on the pointer row: on a 1-row dial there is no spare row, so
          # keep the pointer rather than let the number overwrite it.
          if text_visible? && (ty = yl - 1) != cy
            draw_centered_text ty, xi, xl, value_text
          end
        end
      end
    end
  end
end
