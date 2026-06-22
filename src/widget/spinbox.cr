require "./input"

module Crysterm
  class Widget
    # Spin box element, modeled after Qt's `QSpinBox`.
    #
    # Shows a single integer `#value` (optionally framed by a `#prefix`/`#suffix`,
    # e.g. `"$"` / `" %"`) that the user steps with the Up/Down keys (or the mouse
    # wheel) by `#step`, within `[#minimum, #maximum]`. With `#wrap?` the value
    # rolls over at the bounds. Emits `Event::ValueChange` on every change.
    class SpinBox < Input
      property minimum : Int32 = 0
      property maximum : Int32 = 100
      property step : Int32 = 1

      # Text shown before/after the number (Qt `QSpinBox#prefix`/`#suffix`).
      property prefix : String = ""
      property suffix : String = ""

      # Whether stepping past a bound wraps to the other end (Qt `wrapping`).
      property? wrap : Bool = false

      @value : Int32 = 0

      def initialize(
        value : Int32? = nil,
        @minimum = 0,
        @maximum = 100,
        @step = 1,
        @prefix = "",
        @suffix = "",
        wrap = false,
        **input,
      )
        super **input

        @wrap = wrap
        @value = (value || @minimum).clamp(@minimum, @maximum)

        handle Crysterm::Event::KeyPress

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

      def value : Int32
        @value
      end

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
        update_content
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

      # The text shown in the box: `prefix + value + suffix`.
      def text : String
        "#{@prefix}#{@value}#{@suffix}"
      end

      private def update_content
        set_content text
      end

      def on_keypress(e)
        k = e.key
        ch = e.char
        if k == Tput::Key::Up || ch == 'k' || ch == '+'
          increment
          e.accept
          request_render
        elsif k == Tput::Key::Down || ch == 'j' || ch == '-'
          decrement
          e.accept
          request_render
        elsif k == Tput::Key::PageUp
          increment @step * 10
          e.accept
          request_render
        elsif k == Tput::Key::PageDown
          decrement @step * 10
          e.accept
          request_render
        elsif k == Tput::Key::Home
          self.value = @minimum
          e.accept
          request_render
        elsif k == Tput::Key::End
          self.value = @maximum
          e.accept
          request_render
        end
      end
    end
  end
end
