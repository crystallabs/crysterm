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
      #
      # As in Qt, a new minimum above the current maximum carries the maximum
      # up with it (range collapses to the single value `v`) rather than
      # inverting.
      def minimum=(v : Int32) : Int32
        set_range v, Math.max(v, @maximum)
        @minimum
      end

      # Sets the upper bound (Qt's `setMaximum`), re-clamping the value and
      # emitting `Event::RangeChange` on an actual change. See `#set_range`.
      #
      # As in Qt, a new maximum below the current minimum carries the minimum
      # down with it (range collapses to the single value `v`) rather than
      # inverting.
      def maximum=(v : Int32) : Int32
        set_range Math.min(v, @minimum), v
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

      # Handles a mouse-wheel notch on a ranged control: wheel-up steps the
      # value up by `#step`, wheel-down steps it down. Accepts *e* and returns
      # `true` when the event was a wheel notch (so callers can `next`).
      def ranged_wheel(e) : Bool
        if e.action.wheel_up?
          increment
          e.accept
          true
        elsif e.action.wheel_down?
          decrement
          e.accept
          true
        else
          false
        end
      end

      # Handles the stepping keys shared by `Widget::Slider` and `Widget::Dial`:
      # Up/Right (and `k`/`l`) step up, Down/Left (and `j`/`h`) step down, Page
      # Up/Down move by `#page_step`, and Home/End jump to the bounds. Accepts
      # *e* and returns `true` when a key was handled. Stepping routes through
      # `#value=`, which repaints only on an actual change.
      def ranged_step_key(e) : Bool
        case e.key
        when Tput::Key::Right, Tput::Key::Up
          increment
        when Tput::Key::Left, Tput::Key::Down
          decrement
        when Tput::Key::PageUp
          increment page_step
        when Tput::Key::PageDown
          decrement page_step
        when Tput::Key::Home
          self.value = @minimum
        when Tput::Key::End
          self.value = @maximum
        else
          case e.char
          when 'l', 'k' then increment
          when 'h', 'j' then decrement
          else
            return false
          end
        end
        e.accept
        true
      end

      # Sets both bounds at once (Qt's `setRange(min, max)`). On an actual change
      # it runs `#on_range_changed`, emits `Event::RangeChange`, re-clamps the
      # current value into the new range (which may emit `Event::ValueChange`),
      # and repaints. No-op when neither bound moves.
      def set_range(min : Int32, max : Int32) : Nil
        # Never store an inverted range: `#value=`/`#value_span`/the percent
        # helpers all assume `min <= max`. Mirrors Qt's `setRange`, where a max
        # below min collapses the range to `min`. (`#minimum=`/`#maximum=`
        # already pre-adjust the other bound; this guards a direct call too.)
        max = min if max < min
        return if min == @minimum && max == @maximum
        @minimum = min
        @maximum = max
        on_range_changed
        emit Crysterm::Event::RangeChange, @minimum, @maximum
        # Pre-clamp (rather than let `#value=` handle it) so a `#wrap?` control
        # clamps on a range change instead of wrapping to the opposite bound:
        # an out-of-range `@value` would trip `#value=`'s wrap branch. A
        # pre-clamped value makes that check a no-op, behaving as a plain clamp.
        self.value = @value.clamp(@minimum, @maximum)
        request_render
      end

      # Sets the inclusive `[minimum, maximum]` range from a `Range` (Qt's
      # `setRange`). An exclusive range (`begin...end`) covers `begin..end - 1`,
      # matching Crystal's own `Range` semantics. A degenerate empty exclusive
      # range (`n...n`) collapses to the single value `n` instead of inverting.
      def range=(r : ::Range(Int32, Int32)) : ::Range(Int32, Int32)
        max = r.exclusive? ? Math.max(r.begin, r.end - 1) : r.end
        set_range r.begin, max
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

    # Float-valued range helpers shared by the read-only meter widgets
    # `Widget::Gauge` and `Widget::GaugeList`. Both keep a `Float64`
    # `[minimum, maximum]` range; this provides a `#span` that never reports
    # zero (keeping divisions safe; an empty range simply renders empty) and a
    # `#percent_of` that maps a value onto a `0..100` percentage of that range.
    module PercentRange
      # Size of the value range (`maximum - minimum`), never zero.
      def span : Float64
        s = maximum - minimum
        s <= 0 ? 1.0 : s
      end

      # *value*'s position in `[minimum, maximum]` as a `0..100` percentage.
      def percent_of(value : Float64) : Float64
        ((value - minimum) / span * 100).clamp(0.0, 100.0)
      end
    end
  end
end
