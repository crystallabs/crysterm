module Crysterm
  class Widget
    # Simple Line widget. Draws a horizontal or vertical
    #
    # <!-- widget-examples:capture v1 -->
    # ![Line screenshot](../../tests/widget/line/line.5s.apng)
    # <!-- /widget-examples:capture -->
    class Line < Box
      @resizable = true

      property orientation : Tput::Orientation = :horizontal

      def initialize(@orientation = @orientation, char = nil, size = nil, **box)
        super **box

        # `size` is the line's *length* (`width` when horizontal, `height` when
        # vertical). Apply it when explicitly given; otherwise default to filling
        # the parent (`100%`). Previously `size` defaulted to `"100%"` and was
        # applied unconditionally, silently clobbering an explicit `width:`/
        # `height:` passed through `**box` (e.g. `HLine.new(width: 40)` ended up
        # `100%`-wide).
        if size
          self.line_size = size
        elsif (@orientation.horizontal? ? @width : @height).nil?
          self.line_size = "100%"
        end

        char ||= (@orientation == Tput::Orientation::Vertical ? '│' : '─')

        style.fill_char = char
      end

      # Beyond any border (handled by `super`), a *horizontal* line emits a run
      # of line-drawing characters across its row(s), so those rows must
      # participate in docking. A *vertical* line emits only `│` down a single
      # column and needs no stop of its own — it's docked whenever a horizontal
      # line/border registers the crossing row. See `Crysterm::Docking`.
      def register_dock_stops(coords)
        super

        if @orientation.horizontal?
          (coords.yi..coords.yl - 1).each do |y|
            window._dock_stops[y] = true
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
          # Failsafe case; prevents nothing rendering at all.
          self.width = size
          self.height = size
        end
      end
    end
  end
end
