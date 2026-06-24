require "./input"

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
    # ![DoubleSpinBox screenshot](../../examples/widget/double_spinbox/double_spinbox-capture.png)
    # <!-- /widget-examples:capture -->
    class DoubleSpinBox < Input
      # Honor the given `width` rather than shrinking to the content.
      @resizable = false

      property minimum : Float64 = 0.0
      property maximum : Float64 = 100.0
      property step : Float64 = 1.0

      # Number of fractional digits shown (Qt's `QDoubleSpinBox#decimals`).
      property decimals : Int32 = 2

      # Text shown before/after the number.
      property prefix : String = ""
      property suffix : String = ""

      # Whether stepping past a bound wraps to the other end.
      property? wrap : Bool = false

      # Whether the value can be typed directly.
      property? editable : Bool = true

      @value : Float64 = 0.0
      @editing : String? = nil

      def initialize(
        value : Float64? = nil,
        @minimum = 0.0,
        @maximum = 100.0,
        @step = 1.0,
        @decimals = 2,
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

        on(Crysterm::Event::Blur) { cancel_edit if editing? }

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

      # The text shown in the box: the edit buffer (while editing) or the
      # formatted value, framed by `prefix`/`suffix`.
      def text : String
        body = @editing || formatted_value
        "#{@prefix}#{body}#{@suffix}"
      end

      def editing? : Bool
        !@editing.nil?
      end

      private def update_content
        set_content text
      end

      # Parses and commits the edit buffer (clamped into range), then ends the
      # editing session. An empty/invalid buffer just restores the prior value.
      def commit_edit
        buf = @editing
        return unless buf
        @editing = nil
        if v = buf.to_f?
          self.value = v
        end
        update_content
      end

      def cancel_edit
        return unless @editing
        @editing = nil
        update_content
      end

      def on_keypress(e)
        k = e.key
        ch = e.char

        # Direct entry: digits, a single decimal point, and a leading `-`.
        if editable? && ch &&
           (('0'..'9').includes?(ch) ||
           (ch == '.' && !@editing.to_s.includes?('.')) ||
           (ch == '-' && @minimum < 0 && @editing.nil?))
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
