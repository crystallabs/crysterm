module Crysterm
  module Mixin
    # Shared integer-range value behavior for the numeric controls
    # `Widget::Slider`, `Widget::SpinBox` and `Widget::Dial`: a `#value` kept
    # within `[#minimum, #maximum]` (clamped, or wrapped when `#wrap?`), stepped
    # by `#step`, emitting `Event::ValueChange` only on an actual change.
    #
    # `Widget::ProgressBar` is intentionally *not* built on this: its value drives
    # a derived fill percentage and emits an extra `Event::Complete`, so it keeps
    # its own implementation.
    module RangedValue
      getter minimum : Int32 = 0
      getter maximum : Int32 = 100

      # Sets the lower bound (Qt's `setMinimum`), re-clamping the value and
      # emitting `Event::RangeChange` on an actual change. See `#set_range`.
      def minimum=(v : Int32) : Int32
        set_range v, @maximum
        @minimum
      end

      # Sets the upper bound (Qt's `setMaximum`), re-clamping the value and
      # emitting `Event::RangeChange` on an actual change. See `#set_range`.
      def maximum=(v : Int32) : Int32
        set_range @minimum, v
        @maximum
      end

      # Amount the arrow keys / `#increment` / `#decrement` move the value by.
      property step : Int32 = 1

      # Qt's `singleStep`: an alias for `#step`, the amount a single line-step
      # (arrow key, wheel notch) moves the value by.
      def single_step : Int32
        @step
      end

      # :ditto:
      def single_step=(v : Int32) : Int32
        @step = v
      end

      # Whether stepping past a bound wraps around to the other end.
      property? wrap : Bool = false

      @value : Int32 = 0

      # Current value, within `[#minimum, #maximum]`.
      def value : Int32
        @value
      end

      # Sets the value — wrapping when `#wrap?`, otherwise clamping into range.
      # On an actual change it runs `#on_value_changed`, emits
      # `Event::ValueChange`, and repaints.
      def value=(v : Int32) : Int32
        if wrap? && @maximum > @minimum
          if v > @maximum
            v = @minimum
          elsif v < @minimum
            v = @maximum
          end
        end
        v = v.clamp(@minimum, @maximum)
        return v if v == @value
        @value = v
        on_value_changed
        emit Crysterm::Event::ValueChange, @value
        request_render
        @value
      end

      def increment(by : Int32 = @step)
        self.value = @value + by
      end

      def decrement(by : Int32 = @step)
        self.value = @value - by
      end

      # Size of the value range (`maximum - minimum`), never negative.
      def value_span : Int32
        Math.max(0, @maximum - @minimum)
      end

      # Sets both bounds at once (Qt's `setRange(min, max)`). On an actual change
      # it runs `#on_range_changed`, emits `Event::RangeChange`, re-clamps the
      # current value into the new range (which may emit `Event::ValueChange`),
      # and repaints. No-op when neither bound moves.
      def set_range(min : Int32, max : Int32) : Nil
        return if min == @minimum && max == @maximum
        @minimum = min
        @maximum = max
        on_range_changed
        emit Crysterm::Event::RangeChange, @minimum, @maximum
        # Re-clamp the value into the new range; `#value=` no-ops if unchanged.
        self.value = @value
        request_render
      end

      # Sets the inclusive `[minimum, maximum]` range from a `Range` (Qt's
      # `setRange`). Exclusive ranges are treated as inclusive of `end`.
      def range=(r : ::Range(Int32, Int32)) : ::Range(Int32, Int32)
        set_range r.begin, r.end
        r
      end

      # Overridable hook run (before `Event::RangeChange`) whenever `#minimum`
      # or `#maximum` actually changes. No-op by default.
      protected def on_range_changed
      end

      # Overridable hook run (before `Event::ValueChange`) whenever the value
      # actually changes — e.g. `SpinBox` refreshes its displayed text. No-op by
      # default.
      protected def on_value_changed
      end
    end
  end
end
