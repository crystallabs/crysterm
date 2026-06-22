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
      property minimum : Int32 = 0
      property maximum : Int32 = 100

      # Amount the arrow keys / `#increment` / `#decrement` move the value by.
      property step : Int32 = 1

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

      # Overridable hook run (before `Event::ValueChange`) whenever the value
      # actually changes — e.g. `SpinBox` refreshes its displayed text. No-op by
      # default.
      protected def on_value_changed
      end
    end
  end
end
