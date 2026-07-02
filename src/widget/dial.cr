require "./abstract_slider"

module Crysterm
  class Widget
    # Rotary value selector, modeled after Qt's `QDial`.
    #
    # Picks an integer `#value` within `[#minimum, #maximum]`; the value is shown
    # as a compass-style pointer that sweeps around as it changes (plus the number
    # itself when `#show_value?`). Arrow keys / the mouse wheel rotate it by
    # `#step`, Page Up/Down by `#page_step`, and `#wrap?` rolls over at the ends.
    # Emits `Event::ValueChange` on every change.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Dial screenshot](../../tests/widget/dial/dial.5s.apng)
    # <!-- /widget-examples:capture -->
    class Dial < AbstractSlider
      # A dial draws a fixed-size knob, not shrink-to-content like an `Input`.
      @resizable = false

      property page_step : Int32 = 10

      property? show_value : Bool = true

      # Pointer glyphs for the eight compass directions, starting at "north" and
      # going clockwise.
      POINTERS = ['↑', '↗', '→', '↘', '↓', '↙', '←', '↖']

      def initialize(
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @step = 1,
        @page_step = 10,
        wrap = false,
        @show_value = true,
        **input,
      )
        super **input

        @wrap = wrap
        # Guarded range+value init: never store an inverted range (which would
        # leave `#value` stuck after `clamp`). Shared with `Slider`/`ScrollBar`.
        init_range @minimum, @maximum, value

        handle Crysterm::Event::KeyPress

        on(Crysterm::Event::Mouse) do |e|
          ranged_wheel e
        end
      end

      # The pointer glyph for the current value (one of the eight `POINTERS`,
      # mapping the value's position in the range onto a clockwise angle).
      private def pointer : Char
        s = value_span
        frac = s == 0 ? 0.0 : (@value - @minimum) / s.to_f
        # A wrapping dial maps the range onto the full circle, so the maximum
        # rolls back onto the minimum's "north" (`frac * size` rounds 1.0 → size,
        # `% size` folds to 0). A non-wrapping dial instead spreads the range
        # across the arc between the eight directions: `frac * (size - 1)` lands
        # the maximum on the last glyph (`↖`). With the old unconditional
        # `* size`, a non-wrapping dial showed `↑` at both ends and could skip an
        # in-between direction.
        steps = wrap? ? POINTERS.size : POINTERS.size - 1
        POINTERS[(frac * steps).round.to_i % POINTERS.size]
      end

      def render
        with_inner_coords do |xi, xl, yi, yl|
          window.fill_region sattr(style), style.fill_char, xi, xl, yi, yl

          # Pointer in the middle of the knob. When the value is shown it owns the
          # bottom row (`yl - 1`), so center the pointer in the rows above it
          # (`yi..yl-2`); otherwise the value text would overwrite and hide the
          # pointer on a short (inner height <= 2) dial.
          pointer_bottom = show_value? ? Math.max(yi, yl - 2) : yl
          cx = xi + (xl - xi) // 2
          cy = yi + (pointer_bottom - yi) // 2
          window.lines[cy]?.try do |line|
            line[cx]?.try do |cell|
              cell.char = pointer
              cell.attr = sattr style.indicator
            end
            line.dirty = true
          end

          # Draw the value on the reserved bottom row, but only when it does not
          # land on the pointer row: on a 1-row dial there is no spare row, so
          # keep the pointer rather than let the number overwrite it.
          if show_value? && (ty = yl - 1) != cy
            # Bracket the number while focused to show the dial is active.
            txt = focused? ? "‹#{@value}›" : @value.to_s
            tx = xi + Math.max(0, (xl - xi - txt.size) // 2)
            draw_text_run ty, tx, txt, xl
          end
        end
      end

      # Qt's dial increases clockwise: Up/Right raise, Down/Left lower — the
      # mapping shared with `Slider` via `Mixin::RangedValue#ranged_step_key`.
      def on_keypress(e)
        ranged_step_key e
      end
    end
  end
end
