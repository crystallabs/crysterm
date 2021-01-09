require "./node"
require "./element"
require "./input"

module Crysterm
  module Widget
    # Button element
    class Button < Input
      include EventHandler

      getter value = false

      def initialize(**element)
        super **element
        ## TODO all element's options
        #on(KeyPressEvent) do |key|
        #  if key.name==Enter || Space
        #    press
        #  end
        #end

        # TODO - why conditional? could be cool to trigger clicks by
        # events even if mouse is disabled.
        #if mouse
          on(ClickEvent) do
            press
          end
        #end
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
