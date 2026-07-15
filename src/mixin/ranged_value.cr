module Crysterm
  module Mixin
    # Shared bounded-range value behavior for the numeric controls
    # `Widget::Slider`, `Widget::SpinBox`, `Widget::Dial` and
    # `Widget::DoubleSpinBox`: a `#value` kept within `[#minimum, #maximum]`
    # (clamped, or wrapped when `#wrapping?`), stepped by `#step`, emitting a
    # value-change signal only on an actual change.
    #
    # The module is generic over the numeric type *T*, so the integer controls
    # include `RangedValue(Int32)` and `DoubleSpinBox` includes
    # `RangedValue(Float64)` — collapsing the range machinery each had copied.
    # The two signals differ by type, so they route through the overridable
    # `#emit_value_change`/`#emit_range_change` hooks: the default emits the
    # `Int32` `Event::ValueChanged`/`Event::RangeChanged`, and `DoubleSpinBox`
    # overrides `#emit_value_change` to emit `Event::DoubleValueChanged` (and
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

      # Whether stepping past a bound wraps around to the other end. Qt spells
      # it `wrapping` on both `QAbstractSpinBox` and `QDial`.
      property? wrapping : Bool = false

      # Current value, within `[#minimum, #maximum]`.
      def value : T
        @value
      end

      # Sets the value — wrapping when `#wrapping?`, otherwise clamping into range.
      # On an actual change it runs `#on_value_changed`, emits the value-change
      # signal (via `#emit_value_change`), and repaints.
      def value=(v : T) : T
        if wrapping? && @maximum > @minimum
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
      rescue OverflowError
        # `@value + by` exceeded T's representable range (e.g. Up at
        # `maximum: Int32::MAX`). Saturate to the bound (Qt behavior) instead
        # of letting the exception escape and kill the key/render fiber; a
        # wrapping control wraps to the opposite bound, exactly as an
        # in-range overshoot would.
        step_overflow_saturate(by >= T.zero)
      end

      def decrement(by : T = @step)
        self.value = @value - by
      rescue OverflowError
        step_overflow_saturate(by < T.zero)
      end

      # Steps the value by *steps* line-steps (Qt's `QAbstractSpinBox#stepBy`),
      # saturating/wrapping exactly as `#increment`/`#decrement` do. Negative
      # *steps* move down.
      #
      # These three Qt names are homed here, not on `Widget::AbstractSpinBox`:
      # that base is shared with `Widget::DateTimeEdit`, which has no numeric
      # `@step`/`#increment` at all (it steps a *section* via
      # `Mixin::SectionedField`), so a `step_by` declared there could only be
      # abstract — forcing an implementation into the sectioned editors. Here
      # they land on exactly the types that have a steppable numeric value.
      def step_by(steps : Int32) : Nil
        return if steps == 0
        steps > 0 ? increment(@step * steps) : decrement(@step * -steps)
      rescue OverflowError
        # `@step * steps` overflowed T before `#increment`/`#decrement` could
        # saturate it; the direction is all that survives, which is enough.
        step_overflow_saturate(steps > 0)
      end

      # Steps the value up/down by one `#single_step` (Qt's
      # `QAbstractSpinBox#stepUp`/`#stepDown`). See `#step_by`.
      def step_up : Nil
        increment
      end

      # :ditto:
      def step_down : Nil
        decrement
      end

      # Overflow fallback for `#increment`/`#decrement`: jump to the bound the
      # step was heading for (`upward`), or the opposite one when wrapping.
      private def step_overflow_saturate(upward : Bool) : T
        if wrapping? && @maximum > @minimum
          self.value = upward ? @minimum : @maximum
        else
          self.value = upward ? @maximum : @minimum
        end
      end

      # Size of the value range (`maximum - minimum`), never negative.
      def value_span : T
        {% if T == Int32 %}
          # A full-span integer range (e.g. `Int32::MIN..Int32::MAX`) overflows
          # `@maximum - @minimum` in Int32, so widen the subtraction and clamp
          # back into range.
          (@maximum.to_i64 - @minimum).clamp(0_i64, Int32::MAX.to_i64).to_i
        {% else %}
          Math.max(T.zero, @maximum - @minimum)
        {% end %}
      end

      # Constructor-time range+value initialiser: stores a non-inverted range and
      # a clamped value *directly* (no `Event::RangeChanged`/`ValueChanged` — nothing
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
        # Pre-clamp (rather than let `#value=` handle it) so a `#wrapping?` control
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
      # `Int32` `Event::ValueChanged` used by the integer controls
      # (`Slider`/`Dial`/`ScrollBar`/`SpinBox`); `DoubleSpinBox` overrides it to
      # emit the `Float64` `Event::DoubleValueChanged`. Kept as a hook because the
      # two events are distinct types — a single `emit` here would not type-check
      # across both `T` instantiations.
      protected def emit_value_change : Nil
        emit Crysterm::Event::ValueChanged, @value
      end

      # Emits the range-change signal on an actual change. The default is the
      # `Int32` `Event::RangeChanged`; `DoubleSpinBox` overrides it to a no-op
      # (there is no `Float64` range event).
      protected def emit_range_change : Nil
        emit Crysterm::Event::RangeChanged, @minimum, @maximum
      end
    end

    # Float-valued range helpers shared by the read-only meter widgets
    # `Widget::Gauge`, `Widget::GaugeList` and `Widget::Graph::Donut`. All keep a
    # `Float64` `[minimum, maximum]` range; this provides a `#span` that never
    # reports zero (keeping divisions safe; an empty range simply renders empty)
    # and a `#percent_of` that maps a value onto a `0..100` percentage of that
    # range, plus the shared `#value=` body `#assign_completable`.
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

      # Shared `#value=` body for the read-only `Float64` meters `Widget::Gauge`
      # and `Widget::Graph::Donut`: clamps *v* into `[minimum, maximum]`, and on
      # an actual change stores it, emits `Event::DoubleValueChanged` (the
      # `Float64` value event), emits `Event::Complete` upon reaching `#maximum`
      # (only when the range is non-empty, so an empty `minimum == maximum` bar
      # never "completes"), then runs the widget's own post-change *action* — a
      # repaint (`Gauge`) or Canvas invalidation (`Donut`). Block-yielding, so it
      # allocates no `Proc`. Returns the stored value (matching each site's
      # `#value=` return).
      protected def assign_completable(v : Number, &) : Float64
        v = v.to_f
        # Sanitize non-finite input at ingestion: NaN survives `clamp` (every
        # comparison with NaN is false) and later `NaN.round.to_i` raises
        # OverflowError inside the render fiber, killing it.
        v = minimum unless v.finite?
        v = v.clamp(minimum, maximum)
        return v if v == @value
        @value = v
        emit Crysterm::Event::DoubleValueChanged, @value
        emit Crysterm::Event::Complete if @value == maximum && maximum > minimum
        yield
        @value
      end
    end
  end
end
