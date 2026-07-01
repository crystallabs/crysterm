require "./abstract_spin_box"
require "../mixin/spinbox_editing"

module Crysterm
  class Widget
    # Floating-point spin box, modeled after Qt's `QDoubleSpinBox`.
    #
    # Like `Widget::SpinBox` but the `#value`, `#minimum`, `#maximum` and `#step`
    # are `Float64`, and the displayed number is rounded to `#decimals` places.
    # The value steps with Up/Down (or the wheel) and can be typed directly
    # (digits, one `.`, and a leading `-` when negatives are in range); Enter
    # commits, Escape/blur discards. Emits `Event::DoubleValueChange` on change.
    #
    # It is a separate widget (not built on `Mixin::RangedValue`, which is
    # integer-only) so the integer controls keep their simpler `Int32` path.
    #
    # <!-- widget-examples:capture v1 -->
    # ![DoubleSpinBox screenshot](../../tests/widget/double_spinbox/double_spinbox.5s.apng)
    # <!-- /widget-examples:capture -->
    class DoubleSpinBox < AbstractSpinBox
      # Edit buffer, key dispatch, wheel/blur wiring, `#text`/`#commit_edit`/…
      include Mixin::SpinBoxEditing

      # Honor the given `width` rather than shrinking to the content.
      @resizable = false

      # Lower/upper bounds of the value range (Qt's `minimum`/`maximum`).
      getter minimum : Float64 = 0.0
      getter maximum : Float64 = 100.0
      property step : Float64 = 1.0

      # Sets the lower bound (Qt's `setMinimum`), re-clamping the value into the
      # new range and repainting. See `#set_range`.
      def minimum=(v : Float64) : Float64
        set_range v, @maximum
        @minimum
      end

      # Sets the upper bound (Qt's `setMaximum`), re-clamping the value into the
      # new range and repainting. See `#set_range`.
      def maximum=(v : Float64) : Float64
        set_range @minimum, v
        @maximum
      end

      # Sets both bounds at once (Qt's `setRange`), re-clamping the current value
      # into the new range and scheduling a repaint. Mirrors `SpinBox`
      # (`Mixin::RangedValue#set_range`) and `ProgressBar#set_range`.
      # (`Event::RangeChange` is `Int32`-typed, so — like `ProgressBar` — the
      # float path can't emit it.)
      def set_range(min : Float64, max : Float64) : Nil
        max = min if max < min # never store an inverted range
        return if min == @minimum && max == @maximum
        @minimum = min
        @maximum = max
        # Pre-clamp here rather than leaning on `#value=`, so a `#wrap?` box
        # *clamps* on a range change instead of tripping the wrap branch and
        # snapping to the opposite bound. `#request_render` covers the
        # value-unchanged-but-range-changed case.
        self.value = @value.clamp(@minimum, @maximum)
        request_render
      end

      # Number of fractional digits shown (Qt's `QDoubleSpinBox#decimals`).
      # Never negative — a negative count would make the `"%.*f"` format string
      # malformed and crash; Qt likewise clamps `setDecimals` at 0.
      getter decimals : Int32 = 2

      def decimals=(d : Int32) : Int32
        @decimals = Math.max(d, 0)
        update_content
        @decimals
      end

      # Text shown before/after the number.
      property prefix : String = ""
      property suffix : String = ""

      # Whether stepping past a bound wraps to the other end.
      property? wrap : Bool = false

      # Whether the value can be typed directly.
      property? editable : Bool = true

      @value : Float64 = 0.0

      def initialize(
        value : Float64? = nil,
        @minimum = 0.0,
        @maximum = 100.0,
        @step = 1.0,
        decimals = 2,
        @prefix = "",
        @suffix = "",
        @editable = true,
        wrap = false,
        **input,
      )
        super **input

        @wrap = wrap
        @decimals = Math.max(decimals, 0)
        # Never store an inverted range (mirrors `#set_range`), which would
        # otherwise leave `#value` permanently stuck after `clamp`.
        @maximum = Math.max(@minimum, @maximum)
        @value = (value || @minimum).clamp(@minimum, @maximum)

        handle Crysterm::Event::KeyPress
        install_spinbox_editing

        update_content
      end

      # Current value, within `[#minimum, #maximum]`.
      def value : Float64
        @value
      end

      # Sets the value — wrapping when `#wrap?`, otherwise clamping into range.
      # Emits `Event::DoubleValueChange` only on an actual change.
      def value=(v : Float64) : Float64
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
        update_content
        emit Crysterm::Event::DoubleValueChange, @value
        request_render
        @value
      end

      def increment(by : Float64 = @step)
        self.value = @value + by
      end

      def decrement(by : Float64 = @step)
        self.value = @value - by
      end

      # The value formatted to `#decimals` places.
      def formatted_value : String
        "%.#{@decimals}f" % @value
      end

      # The committed value as shown in the box (`Mixin::SpinBoxEditing` hook).
      protected def body_text : String
        formatted_value
      end

      # Parse the edit buffer to this widget's `Float64` (`Mixin::SpinBoxEditing`
      # hook); `nil` on failure.
      protected def parse_buffer(buf : String) : Float64?
        buf.to_f?
      end

      # Double spin box: also accepts a single decimal point as an entry char.
      protected def extra_entry_char?(ch : Char) : Bool
        ch == '.' && !@editing.to_s.includes?('.')
      end
    end
  end
end
