module Crysterm
  module Mixin
    # Shared bounded-range value behavior for the numeric controls
    # `Widget::Slider`, `Widget::SpinBox`, `Widget::Dial` and
    # `Widget::DoubleSpinBox`: a `#value` kept within `[#minimum, #maximum]`
    # (clamped, or wrapped when `#wrap?`), stepped by `#step`, emitting a
    # value-change signal only on an actual change.
    #
    # The module is generic over the numeric type *T*, so the integer controls
    # include `RangedValue(Int32)` and `DoubleSpinBox` includes
    # `RangedValue(Float64)` — collapsing the range machinery each had copied.
    # The two signals differ by type, so they route through the overridable
    # `#emit_value_change`/`#emit_range_change` hooks: the default emits the
    # `Int32` `Event::ValueChange`/`Event::RangeChange`, and `DoubleSpinBox`
    # overrides `#emit_value_change` to emit `Event::DoubleValueChange` (and
    # `#emit_range_change` to a no-op, since there is no `Float64` range event).
    #
    # `Widget::ProgressBar` is intentionally *not* built on this even though its
    # range is `Int32`: its value drives a derived fill percentage and emits an
    # extra `Event::Complete` gated on a `complete:` flag that a range-shrink
    # re-clamp must suppress — a shape `#value=`/`#set_range` here can't express —
    # so it keeps its own implementation.
    module RangedValue(T)
      @minimum : T = T.zero
      @maximum : T = T.zero
      @value : T = T.zero
      @step : T = T.zero

      # Current lower/upper bounds of the value range.
      def minimum : T
        @minimum
      end

      # :ditto:
      def maximum : T
        @maximum
      end

      # Sets the lower bound (Qt's `setMinimum`), re-clamping the value and
      # emitting the range-change signal on an actual change. See `#set_range`.
      #
      # As in Qt, a new minimum above the current maximum carries the maximum
      # up with it (range collapses to the single value `v`) rather than
      # inverting.
      def minimum=(v : T) : T
        set_range v, Math.max(v, @maximum)
        @minimum
      end

      # Sets the upper bound (Qt's `setMaximum`), re-clamping the value and
      # emitting the range-change signal on an actual change. See `#set_range`.
      #
      # As in Qt, a new maximum below the current minimum carries the minimum
      # down with it (range collapses to the single value `v`) rather than
      # inverting.
      def maximum=(v : T) : T
        set_range Math.min(v, @minimum), v
        @maximum
      end

      # Amount the arrow keys / `#increment` / `#decrement` move the value by.
      def step : T
        @step
      end

      # :ditto:
      def step=(v : T) : T
        @step = v
      end

      # Qt's `singleStep`: an alias for `#step`, the amount a single line-step
      # (arrow key, wheel notch) moves the value by.
      def single_step : T
        @step
      end

      # :ditto:
      def single_step=(v : T) : T
        @step = v
      end

      # Whether stepping past a bound wraps around to the other end.
      property? wrap : Bool = false

      # Current value, within `[#minimum, #maximum]`.
      def value : T
        @value
      end

      # Sets the value — wrapping when `#wrap?`, otherwise clamping into range.
      # On an actual change it runs `#on_value_changed`, emits the value-change
      # signal (via `#emit_value_change`), and repaints.
      def value=(v : T) : T
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
        emit_value_change
        request_render
        @value
      end

      def increment(by : T = @step)
        self.value = @value + by
      end

      def decrement(by : T = @step)
        self.value = @value - by
      end

      # Size of the value range (`maximum - minimum`), never negative.
      def value_span : T
        Math.max(T.zero, @maximum - @minimum)
      end

      # Constructor-time range+value initialiser: stores a non-inverted range and
      # a clamped value *directly* (no `Event::RangeChange`/`ValueChange` — nothing
      # is listening during construction). Call from a subclass constructor so the
      # "never store an inverted range" guard (which `#value=`/`#value_span`/the
      # percent helpers all assume) can't be forgotten — e.g.
      # `ScrollBar.new(minimum: 100, maximum: 0)` must not store an inverted range.
      protected def init_range(min : T, max : T, value : T? = nil) : Nil
        @minimum = min
        @maximum = Math.max(min, max)
        @value = (value || @minimum).clamp(@minimum, @maximum)
      end

      # Handles a mouse-wheel notch on a ranged control: wheel-up steps the
      # value up by `#step`, wheel-down steps it down. Accepts *e* and returns
      # `true` when the event was a wheel notch (so callers can `next`).
      #
      # `invert: true` swaps the two (wheel-up decrements) — a vertical
      # `ScrollBar`, whose value grows downward, wants that.
      def ranged_wheel(e, invert : Bool = false) : Bool
        if e.action.wheel_up?
          invert ? decrement : increment
          e.accept
          true
        elsif e.action.wheel_down?
          invert ? increment : decrement
          e.accept
          true
        else
          false
        end
      end

      # Handles the stepping keys shared by `Widget::Slider`, `Widget::Dial` and
      # `Widget::ScrollBar`: Right (and `l`) steps up, Left (and `h`) steps down,
      # Up/Down (and `k`/`j`) and Page Up/Down step the vertical axis, and
      # Home/End jump to the bounds. Accepts *e* and returns `true` when a key was
      # handled; stepping routes through `#value=`, which repaints only on a real
      # change.
      #
      # `invert: true` flips only the *vertical* keys (Up/Down, PageUp/PageDown,
      # `k`/`j`) so a scroll bar's up-arrow decreases the value while its
      # left/right stay conventional.
      def ranged_step_key(e, invert : Bool = false) : Bool
        case e.key
        when Tput::Key::Right
          increment
        when Tput::Key::Left
          decrement
        when Tput::Key::Up
          invert ? decrement : increment
        when Tput::Key::Down
          invert ? increment : decrement
        when Tput::Key::PageUp
          invert ? decrement(page_step) : increment(page_step)
        when Tput::Key::PageDown
          invert ? increment(page_step) : decrement(page_step)
        when Tput::Key::Home
          self.value = @minimum
        when Tput::Key::End
          self.value = @maximum
        else
          case e.char
          when 'l' then increment
          when 'h' then decrement
          when 'k' then invert ? decrement : increment
          when 'j' then invert ? increment : decrement
          else
            return false
          end
        end
        e.accept
        true
      end

      # Sets both bounds at once (Qt's `setRange(min, max)`). On an actual change
      # it runs `#on_range_changed`, emits the range-change signal (via
      # `#emit_range_change`), re-clamps the current value into the new range
      # (which may emit a value change), and repaints. No-op when neither bound
      # moves.
      def set_range(min : T, max : T) : Nil
        # Never store an inverted range: `#value=`/`#value_span`/the percent
        # helpers all assume `min <= max`. Mirrors Qt's `setRange`, where a max
        # below min collapses the range to `min`. (`#minimum=`/`#maximum=`
        # already pre-adjust the other bound; this guards a direct call too.)
        max = min if max < min
        return if min == @minimum && max == @maximum
        @minimum = min
        @maximum = max
        on_range_changed
        emit_range_change
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
      def range=(r : ::Range(T, T)) : ::Range(T, T)
        max = r.exclusive? ? Math.max(r.begin, r.end - 1) : r.end
        set_range r.begin, max
        r
      end

      # Overridable hook run (before the range-change signal) whenever `#minimum`
      # or `#maximum` actually changes. No-op by default.
      protected def on_range_changed
      end

      # Overridable hook run (before the value-change signal) whenever the value
      # actually changes — e.g. `SpinBox` refreshes its displayed text. No-op by
      # default.
      protected def on_value_changed
      end

      # Emits the value-change signal on an actual change. The default is the
      # `Int32` `Event::ValueChange` used by the integer controls
      # (`Slider`/`Dial`/`ScrollBar`/`SpinBox`); `DoubleSpinBox` overrides it to
      # emit the `Float64` `Event::DoubleValueChange`. Kept as a hook because the
      # two events are distinct types — a single `emit` here would not type-check
      # across both `T` instantiations.
      protected def emit_value_change : Nil
        emit Crysterm::Event::ValueChange, @value
      end

      # Emits the range-change signal on an actual change. The default is the
      # `Int32` `Event::RangeChange`; `DoubleSpinBox` overrides it to a no-op
      # (there is no `Float64` range event).
      protected def emit_range_change : Nil
        emit Crysterm::Event::RangeChange, @minimum, @maximum
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
