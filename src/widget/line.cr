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

        # `size` is the line's *length* (its `width` when horizontal, its `height`
        # when vertical). Apply it when explicitly given; otherwise default a line
        # that was given no length to fill its parent (`100%`). Previously `size`
        # defaulted to `"100%"` and was applied unconditionally, so it silently
        # clobbered an explicit `width:`/`height:` passed through `**box` — e.g.
        # `HLine.new(width: 40)` (or the `width: 40` in the hline example) ended up
        # `100%`-wide, and `VLine.new(height: 16)` `100%`-tall, ignoring the value.
        if size
          self.line_size = size
        elsif (@orientation.horizontal? ? @width : @height).nil?
          self.line_size = "100%"
        end

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
          # Almost useless failsafe case; just prevents having nothing rendering on window.
          self.width = size
          self.height = size
        end
      end
    end
  end
end
