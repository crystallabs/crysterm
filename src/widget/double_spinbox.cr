require "./abstract_spin_box"
require "../mixin/ranged_value"
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
    # Its value/range logic is `Mixin::RangedValue(Float64)` — the same generic
    # bounded-range machinery the integer controls use as `RangedValue(Int32)`;
    # it overrides only the value-change signal (`Event::DoubleValueChange`
    # instead of the `Int32` `Event::ValueChange`).
    #
    # <!-- widget-examples:capture v1 -->
    # ![DoubleSpinBox screenshot](../../tests/widget/double_spinbox/double_spinbox.5s.apng)
    # <!-- /widget-examples:capture -->
    class DoubleSpinBox < AbstractSpinBox
      # Range/value behavior (`#minimum`/`#maximum`/`#value`/`#step`/`#wrap?`,
      # `#increment`/`#decrement`, `#set_range`), in `Float64`.
      include Mixin::RangedValue(Float64)

      # Edit buffer, key dispatch, wheel/blur wiring, `#text`/`#commit_edit`/…
      include Mixin::SpinBoxEditing

      # Honor the given `width` rather than shrinking to the content.
      @resizable = false

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

      # Whether the value can be typed directly.
      property? editable : Bool = true

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
        # Store a non-inverted range and a clamped value (the shared guard;
        # `RangedValue#init_range` does the `maximum >= minimum` fix-up that an
        # inverted range would otherwise leave `#value` stuck under).
        init_range @minimum, @maximum, value

        handle Crysterm::Event::KeyPress
        install_spinbox_editing

        update_content
      end

      # Refresh the displayed number whenever the value changes (`RangedValue`
      # hook), mirroring `SpinBox`.
      protected def on_value_changed
        update_content
      end

      # Emit the `Float64` value-change signal (`RangedValue` hook); the integer
      # controls emit `Event::ValueChange` here instead.
      protected def emit_value_change : Nil
        emit Crysterm::Event::DoubleValueChange, @value
      end

      # No `Float64` range-change event exists, so range changes emit nothing
      # (as before); `RangedValue#set_range` still re-clamps and repaints.
      protected def emit_range_change : Nil
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
