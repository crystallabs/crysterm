require "./abstract_spin_box"
require "../mixin/ranged_value"
require "../mixin/spinbox_editing"

module Crysterm
  class Widget
    # Spin box element, modeled after Qt's `QSpinBox`.
    #
    # Shows a single integer `#value` (optionally framed by a `#prefix`/`#suffix`,
    # e.g. `"$"` / `" %"`) that the user steps with the Up/Down keys (or the mouse
    # wheel) by `#step`, within `[#minimum, #maximum]`. With `#wrap?` the value
    # rolls over at the bounds. Emits `Event::ValueChange` on every change.
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
      # Range/value behavior (`#minimum`/`#maximum`/`#value`/`#step`/`#wrap?`,
      # `#increment`/`#decrement`, `Event::ValueChange`).
      include Mixin::RangedValue(Int32)

      # Edit buffer, key dispatch, wheel/blur wiring, `#text`/`#commit_edit`/…
      include Mixin::SpinBoxEditing

      # A spin box honors its given `width` rather than shrinking to its content.
      @resizable = false

      # Text shown before/after the number (Qt `QSpinBox#prefix`/`#suffix`).
      property prefix : String = ""
      property suffix : String = ""

      # Whether the value can be typed directly (Qt's `QAbstractSpinBox#readOnly`
      # inverted). When false the box only responds to stepping.
      property? editable : Bool = true

      def initialize(
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @step = 1,
        @prefix = "",
        @suffix = "",
        @editable = true,
        wrap = false,
        **input,
      )
        super **input

        @wrap = wrap
        # Never store an inverted range (mirrors `Mixin::RangedValue#set_range`),
        # which would otherwise leave `#value` permanently stuck after `clamp`.
        @maximum = Math.max(@minimum, @maximum)
        @value = (value || @minimum).clamp(@minimum, @maximum)

        handle Crysterm::Event::KeyPress
        install_spinbox_editing

        update_content
      end

      # Refresh the displayed number whenever the value changes (mixin hook).
      protected def on_value_changed
        update_content
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
