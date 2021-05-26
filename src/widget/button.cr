require "./node"
require "./element"
require "./input"

module Crysterm
  module Widget
    # Button element
    class Button < Input
      include EventHandler

      getter value = false

      def initialize(**input)
        super **input

        on(Crysterm::Event::KeyPress) do |e|
          # if e.key == Tput::Key::Enter || e.key == Tput::Key::Space
          if e.key == Tput::Key::Enter || e.char == ' '
            e.accept!
            press
          end
        end

        on(Crysterm::Event::Click) do |e|
          # e.accept!
          press
        end
        # end
      end

      def press
        focus
        @value = true
        emit Crysterm::Event::Press
        @value = false
      end
    end
  end
end
