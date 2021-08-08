require "./input"

module Crysterm
  class Widget
    # Button element
    class Button < Input
      include EventHandler

      getter value = false

      def initialize(**input)
        super **input

        on Crysterm::Event::KeyPress, ->on_keypress(Crysterm::Event::KeyPress)
        on Crysterm::Event::Click, ->on_click(Crysterm::Event::Click)
      end

      def press
        focus
        @value = true
        emit Crysterm::Event::Press
        @value = false
      end

      def on_keypress(e)
        if e.char == ' ' || e.key.try(&.==(::Tput::Key::Enter))
          e.accept!
          press
        end
      end

      def on_click(e)
        # e.accept!
        press
      end
    end
  end
end
