module Crysterm
  class Widget
    # Simple Line widget. Draws a horizontal or vertical
    #
    # <!-- widget-examples:capture v1 -->
    # ![Line screenshot](../../examples/widget/line/line-capture.png)
    # <!-- /widget-examples:capture -->
    class Line < Box
      @resizable = true

      property orientation : Tput::Orientation = :horizontal

      def initialize(@orientation = @orientation, char = nil, size = "100%", **box)
        super **box

        size.try { |s| self.line_size = s }

        char ||= (@orientation == Tput::Orientation::Vertical ? '│' : '─')

        style.fill_char = char
      end

      # In addition to any border (handled by `super`), a *horizontal* line
      # emits a horizontal run of line-drawing characters across its row(s), so
      # those rows must participate in docking. A *vertical* line emits only
      # `│` down a single column; it needs no stop of its own, as it is docked
      # whenever a horizontal line/border registers the crossing row.
      # See `Crysterm::Docking`.
      def register_dock_stops(coords)
        super

        if @orientation.horizontal?
          (coords.yi..coords.yl - 1).each do |y|
            screen._dock_stops[y] = true
          end
        end
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
