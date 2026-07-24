require "./abstract_spin_box"
require "../mixin/ranged_value"
require "../mixin/spinbox_editing"

module Crysterm
  class Widget
    # Spin box element, modeled after Qt's `QSpinBox`.
    #
    # Shows a single integer `#value` (optionally framed by a `#prefix`/`#suffix`,
    # e.g. `"$"` / `" %"`) that the user steps with the Up/Down keys (or the mouse
    # wheel) by `#step`, within `[#minimum, #maximum]`. With `#wrapping?` the value
    # rolls over at the bounds. Emits `Event::ValueChanged` on every change.
    #
    # The number can also be typed directly (Qt's `QAbstractSpinBox` is editable
    # by default): typing a digit (or a leading `-`) starts an edit buffer,
    # Backspace edits it, Enter commits the parsed value (clamped into range),
    # and Escape — or losing focus — discards the edit and restores the value.
    #
    # <!-- widget-examples:capture v1 -->
    # ![SpinBox screenshot](../../tests/widget/spinbox/spinbox.5s.apng)
    # <!-- /widget-examples:capture -->
    class SpinBox < AbstractSpinBox
      # Range/value behavior (`#minimum`/`#maximum`/`#value`/`#step`/`#wrapping?`,
      # `#step_up`/`#step_down`, `Event::ValueChanged`).
      include Mixin::RangedValue(Int32)

      # Edit buffer, key dispatch, wheel/blur wiring, `#text`/`#commit_edit`/…
      include Mixin::SpinBoxEditing

      def initialize(
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @step = 1,
        @prefix = "",
        @suffix = "",
        @editable = true,
        wrapping = false,
        **input,
      )
        super **{keys: true}.merge(input)

        setup_spinbox_editing value, wrapping
      end

      # The committed value as shown in the box (`Mixin::SpinBoxEditing` hook).
      protected def body_text : String
        @value.to_s
      end

      # Parse the edit buffer to this widget's `Int32` (`Mixin::SpinBoxEditing`
      # hook); `nil` on failure.
      protected def parse_buffer(buf : String) : Int32?
        buf.to_i?
      end

      # Integer spin box: no entry characters beyond digits and a leading sign.
      protected def extra_entry_char?(ch : Char) : Bool
        false
      end
    end
  end
end
