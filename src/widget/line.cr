module Crysterm
  class Widget
    # Simple Line widget. Draws a horizontal or vertical
    class Line < Box
      @resizable = true

      property orientation : Tput::Orientation = :horizontal

      def initialize(@orientation = @orientation, char = nil, size = "100%", **box)
        super **box

        size.try { |s| self.line_size = s }

        char ||= (@orientation == Tput::Orientation::Vertical ? '│' : '─')

        style.char = char
      end

      def line_size=(size)
        case @orientation
        when Tput::Orientation::Horizontal
          self.width = size
        when Tput::Orientation::Vertical
          self.height = size
        else
          # Almost useless failsafe case; just prevents having nothing rendering on screen.
          self.width = size
          self.height = size
        end
      end
    end
  end
end
