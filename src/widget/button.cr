require "./node"
require "./element"
require "./input"

module Crysterm
  module Widget
    # Button element
    class Button < Input
      include EventHandler

      # XXX Do we need this at all? See how `press` is implemented; switching this
      # to true then back to false seems like a bad choice for multiple threads.
      # Why not just assume that a Event::Press implies a yes/valid/active click?
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
