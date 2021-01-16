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
      # Why not just assume that a PressEvent implies a yes/valid/active click?
      getter value = false

      def initialize(**input)
        super **input

        on(KeyPressEvent) do |e|
          #if e.key == Tput::Key::Enter || e.key == Tput::Key::Space
          if e.key == Tput::Key::Enter || e.char == ' '
            e.accept!
            press
          end
        end

        # TODO - why conditional? could be cool to trigger clicks by
        # events even if mouse is disabled.
        # if mouse
          on(ClickEvent) do |e|
            #e.accept!
            press
          end
        # end
      end

      def press
        focus
        @value = true
        emit PressEvent
        @value = false
      end
    end
  end
end
