require "./input"
require "../mixin/ranged_value"

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
    # ![SpinBox screenshot](../../examples/widget/spinbox/spinbox-capture.png)
    # <!-- /widget-examples:capture -->
    class SpinBox < Input
      # Range/value behavior (`#minimum`/`#maximum`/`#value`/`#step`/`#wrap?`,
      # `#increment`/`#decrement`, `Event::ValueChange`).
      include Mixin::RangedValue

      # A spin box honors its given `width` rather than shrinking to its content.
      @resizable = false

      # Text shown before/after the number (Qt `QSpinBox#prefix`/`#suffix`).
      property prefix : String = ""
      property suffix : String = ""

      # Whether the value can be typed directly (Qt's `QAbstractSpinBox#readOnly`
      # inverted). When false the box only responds to stepping.
      property? editable : Bool = true

      # The in-progress edit buffer (`nil` when not editing). While editing, the
      # box shows this text instead of the committed value.
      @editing : String? = nil

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
        @value = (value || @minimum).clamp(@minimum, @maximum)

        handle Crysterm::Event::KeyPress

        # Losing focus mid-edit discards the buffer (Qt restores the last valid
        # value rather than committing a half-typed one).
        on(Crysterm::Event::Blur) { cancel_edit if editing? }

        # Mouse wheel nudges the value.
        on(Crysterm::Event::Mouse) do |e|
          if e.action.wheel_up?
            increment
            e.accept
            request_render
          elsif e.action.wheel_down?
            decrement
            e.accept
            request_render
          end
        end

        update_content
      end

      # The text shown in the box: the edit buffer (while editing) or the
      # committed value, framed by `prefix`/`suffix`.
      def text : String
        body = @editing || @value.to_s
        "#{@prefix}#{body}#{@suffix}"
      end

      # Whether a value is currently being typed.
      def editing? : Bool
        !@editing.nil?
      end

      private def update_content
        set_content text
      end

      # Refresh the displayed number whenever the value changes (mixin hook).
      protected def on_value_changed
        update_content
      end

      # Parses and commits the edit buffer (clamped into range), then ends the
      # editing session. An empty/invalid buffer just restores the prior value.
      def commit_edit
        buf = @editing
        return unless buf
        @editing = nil
        if v = buf.to_i?
          self.value = v # clamps and emits ValueChange if it actually changed
        end
        update_content # revert the display even when the value did not change
      end

      # Abandons the edit buffer and restores the committed value.
      def cancel_edit
        return unless @editing
        @editing = nil
        update_content
      end

      def on_keypress(e)
        k = e.key
        ch = e.char

        # Direct numeric entry: digits (and a leading `-` when negatives are in
        # range) build the edit buffer.
        if editable? && ch && (('0'..'9').includes?(ch) || (ch == '-' && @minimum < 0 && @editing.nil?))
          @editing = (@editing || "") + ch
          update_content
          e.accept
          request_render
          return
        end

        if k == Tput::Key::Enter
          commit_edit
          e.accept
          request_render
        elsif k == Tput::Key::Escape
          cancel_edit
          e.accept
          request_render
        elsif (k == Tput::Key::Backspace || k == Tput::Key::CtrlH) && editing?
          @editing = @editing.to_s[0...-1]
          update_content
          e.accept
          request_render
        elsif k == Tput::Key::Up || ch == 'k' || ch == '+'
          cancel_edit
          increment
          e.accept
          request_render
        elsif k == Tput::Key::Down || ch == 'j'
          cancel_edit
          decrement
          e.accept
          request_render
        elsif k == Tput::Key::PageUp
          cancel_edit
          increment @step * 10
          e.accept
          request_render
        elsif k == Tput::Key::PageDown
          cancel_edit
          decrement @step * 10
          e.accept
          request_render
        elsif k == Tput::Key::Home
          cancel_edit
          self.value = @minimum
          e.accept
          request_render
        elsif k == Tput::Key::End
          cancel_edit
          self.value = @maximum
          e.accept
          request_render
        end
      end
    end
  end
end
