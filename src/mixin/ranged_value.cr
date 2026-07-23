module Crysterm
  module Mixin
    # Shared bounded-range value behavior for numeric controls: a `#value` kept
    # within `[#minimum, #maximum]` (clamped, or wrapped when `#wrapping?`),
    # stepped by `#single_step`, emitting a value-change signal only on an actual change.
    #
    # Generic over the numeric type *T*: integer controls include
    # `RangedValue(Int32)`, float ones `RangedValue(Float64)`. Because the two
    # signals are distinct types, they route through the overridable
    # `#emit_value_change`/`#emit_range_change` hooks, defaulting to the `Int32`
    # `Event::ValueChanged`/`Event::RangeChanged`.
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

      # Qt's `singleStep`: the amount a single line-step (arrow key, wheel notch)
      # moves the value by.
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
        # Sanitize non-finite input at ingestion for float instantiations: NaN
        # survives `clamp` (every comparison with NaN is false) and never equals
        # `@value`, so it would store, render "nan", and re-fire the change event
        # on every step. No-op for the Int32 includers. Mirrors
        # `PercentRange#assign_completable` and the B16-38 convention.
        {% unless T < Int %} v = @minimum unless v.finite? {% end %}
        v = v.clamp(@minimum, @maximum)
        return v if v == @value
        @value = v
        on_value_changed
        emit_value_change
        request_render
        @value
      end

      # Steps the value up by *by* (defaults to one `#single_step`), saturating
      # to the bound on overflow. Internal engine behind `#step_up`/`#step_by`.
      protected def step_value_up(by : T = @step)
        self.value = @value + by
      rescue OverflowError
        # `@value + by` exceeded T's representable range (e.g. Up at
        # `maximum: Int32::MAX`). Saturate to the bound (Qt behavior) rather than
        # let the exception escape and kill the key/render fiber; a wrapping
        # control wraps to the opposite bound, as an in-range overshoot would.
        step_overflow_saturate(by >= T.zero)
      end

      # Steps the value down by *by* (defaults to one `#single_step`), saturating
      # to the bound on overflow. Internal engine behind `#step_down`/`#step_by`.
      protected def step_value_down(by : T = @step)
        self.value = @value - by
      rescue OverflowError
        step_overflow_saturate(by < T.zero)
      end

      # Steps the value by *steps* line-steps (Qt's `QAbstractSpinBox#stepBy`),
      # saturating/wrapping exactly as `#step_up`/`#step_down` do. Negative
      # *steps* move down.
      def step_by(steps : Int32) : Nil
        return if steps == 0
        steps > 0 ? step_value_up(@step * steps) : step_value_down(@step * -steps)
      rescue OverflowError
        # `@step * steps` overflowed T before the step could saturate it; the
        # direction is all that survives, which is enough.
        step_overflow_saturate(steps > 0)
      end

      # Steps the value up/down by one `#single_step` (Qt's
      # `QAbstractSpinBox#stepUp`/`#stepDown`). See `#step_by`.
      def step_up : Nil
        step_value_up
      end

      # :ditto:
      def step_down : Nil
        step_value_down
      end

      # Overflow fallback for the steppers: jump to the bound the
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

      # Constructor-time range+value initialiser: stores a non-inverted range and a
      # clamped value *directly* (no `Event::RangeChanged`/`ValueChanged` — nothing
      # is listening during construction). Call from a subclass constructor so the
      # "never store an inverted range" guard — which `#value=`/`#value_span`/the
      # percent helpers all assume — can't be forgotten.
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
      def ranged_wheel(e : ::Crysterm::Event::Mouse, *, invert : Bool = false) : Bool
        if e.action.wheel_up?
          invert ? step_value_down : step_value_up
          e.accept
          true
        elsif e.action.wheel_down?
          invert ? step_value_up : step_value_down
          e.accept
          true
        else
          false
        end
      end

      # Handles the shared stepping keys: Right (and `l`) steps up, Left (and `h`)
      # steps down, Up/Down (and `k`/`j`) and Page Up/Down step the vertical axis,
      # and Home/End jump to the bounds. Accepts *e* and returns `true` when a key
      # was handled; stepping routes through `#value=`, which repaints only on a
      # real change.
      #
      # `invert: true` flips only the *vertical* keys (Up/Down, PageUp/PageDown,
      # `k`/`j`) so a scroll bar's up-arrow decreases the value while its
      # left/right stay conventional.
      protected def ranged_step_key(e : ::Crysterm::Event::KeyPress, *, invert : Bool = false) : Bool
        case e.key
        when Tput::Key::Right
          step_value_up
        when Tput::Key::Left
          step_value_down
        when Tput::Key::Up
          invert ? step_value_down : step_value_up
        when Tput::Key::Down
          invert ? step_value_up : step_value_down
        when Tput::Key::PageUp
          invert ? step_value_down(page_step) : step_value_up(page_step)
        when Tput::Key::PageDown
          invert ? step_value_up(page_step) : step_value_down(page_step)
        when Tput::Key::Home
          self.value = @minimum
        when Tput::Key::End
          self.value = @maximum
        else
          case e.char
          when 'l' then step_value_up
          when 'h' then step_value_down
          when 'k' then invert ? step_value_down : step_value_up
          when 'j' then invert ? step_value_up : step_value_down
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
        # below min collapses the range to `min`.
        # Reject non-finite bounds as a no-op for float instantiations: NaN would
        # pass the inversion and no-op guards below (all NaN comparisons false) and
        # get stored, wedging clamp/stepping. No-op for the Int32 includers.
        # Matches the B16-38 reject-as-no-op convention.
        {% unless T < Int %} return unless min.finite? && max.finite? {% end %}
        max = min if max < min
        return if min == @minimum && max == @maximum
        @minimum = min
        @maximum = max
        on_range_changed
        emit_range_change
        # Pre-clamp so a `#wrapping?` control clamps on a range change instead of
        # wrapping to the opposite bound: an out-of-range `@value` would trip
        # `#value=`'s wrap branch.
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
      # actually changes. No-op by default.
      protected def on_value_changed
      end

      # Emits the value-change signal on an actual change. Defaults to the `Int32`
      # `Event::ValueChanged`; a `Float64` control overrides it to emit
      # `Event::DoubleValueChanged`. A hook rather than a plain `emit` because the
      # two events are distinct types, which would not type-check across both `T`
      # instantiations.
      protected def emit_value_change : Nil
        emit Crysterm::Event::ValueChanged, @value
      end

      # Emits the range-change signal on an actual change. Defaults to the `Int32`
      # `Event::RangeChanged`; a `Float64` control overrides it to a no-op, there
      # being no `Float64` range event.
      protected def emit_range_change : Nil
        emit Crysterm::Event::RangeChanged, @minimum, @maximum
      end
    end

    # Float-valued range helpers for read-only meter widgets, which keep a
    # `Float64` `[minimum, maximum]` range. Provides a `#span` that never reports
    # zero (keeping divisions safe; an empty range simply renders empty), a
    # `#percent_of` that maps a value onto a `0..100` percentage of that range,
    # and the shared `#value=` body `#assign_completable`.
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

      # Constructor-time bound sanitizer: neutralizes a non-finite *min*/*max*
      # before they're ever stored, mirroring `#set_range`'s reject-outright
      # guard (a NaN bound would survive `max < min` and every later `clamp`,
      # then crash the render fiber on `.round.to_i`). Unlike `set_range`
      # (which rejects a bad call outright and keeps the previous range), a
      # constructor has no previous range to fall back to, so a non-finite
      # `min` collapses to `0.0` and a non-finite `max` collapses to `min`.
      # `max < min` still collapses `max` up to `min`, as `set_range` does.
      # Call before any value sanitization that assumes a finite `minimum`.
      protected def sanitize_range(min : Float64, max : Float64) : {Float64, Float64}
        min = 0.0 unless min.finite?
        max = min unless max.finite?
        max = min if max < min
        {min, max}
      end

      # Shared `#value=` body for a read-only `Float64` meter: clamps *v* into
      # `[minimum, maximum]`, and on an actual change stores it, emits
      # `Event::DoubleValueChanged`, emits `Event::Completed` upon reaching
      # `#maximum` (only when the range is non-empty, so an empty
      # `minimum == maximum` bar never "completes"), then runs the widget's own
      # post-change block. Block-yielding, so it allocates no `Proc`. Returns the
      # stored value.
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
        emit Crysterm::Event::Completed if @value == maximum && maximum > minimum
        yield
        @value
      end
    end
  end
end
