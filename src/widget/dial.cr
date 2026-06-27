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
    # ![Dial screenshot](../../examples/widget/dial/dial-capture5s.apng)
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
        @value = (value || @minimum).clamp(@minimum, @maximum)

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
        # which `% size` folds to 0). A non-wrapping dial must instead spread the
        # range across the arc between the eight directions: `frac * (size - 1)`
        # lands the maximum on the *last* glyph (`↖`), so the two ends point in
        # distinct directions. With the old unconditional `* size`, a non-wrapping
        # dial showed `↑` at both ends (a full dial looked identical to an empty
        # one) and could skip an in-between direction (e.g. `↓` on an 8-value range).
        steps = wrap? ? POINTERS.size : POINTERS.size - 1
        POINTERS[(frac * steps).round.to_i % POINTERS.size]
      end

      def render
        with_inner_coords do |xi, xl, yi, yl|
          screen.fill_region sattr(style), style.fill_char, xi, xl, yi, yl

          # Pointer in the middle of the knob.
          cx = xi + (xl - xi) // 2
          cy = yi + (yl - yi) // 2
          screen.lines[cy]?.try do |line|
            line[cx]?.try do |cell|
              cell.char = pointer
              cell.attr = sattr style.indicator
            end
            line.dirty = true
          end

          if show_value?
            # Bracket the number while focused so it's obvious the dial is the
            # active control (arrow keys / wheel rotate it).
            txt = focused? ? "‹#{@value}›" : @value.to_s
            tx = xi + Math.max(0, (xl - xi - txt.size) // 2)
            ty = yl - 1
            screen.lines[ty]?.try do |line|
              txt.each_char_with_index do |ch, i|
                break if tx + i >= xl
                line[tx + i]?.try &.char = ch
              end
              line.dirty = true
            end
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
