require "../box"

module Crysterm
  class Widget
    # Namespace for data-graphing widgets.
    module Graph
      # A vertical bar graph drawn with Unicode block elements (`▁▂▃▄▅▆▇█`).
      #
      # Each value in `values` becomes one column, a bar rising from the bottom
      # whose height is the value's fraction of the `min`..`max` range — using
      # the eighth-block glyphs for the top cell, so a bar has ~8× the vertical
      # resolution of whole cells. With a height of 1 it degenerates into a
      # one-row *sparkline*.
      #
      # Set `values` (any numeric array) and re-render; the widget rescales and
      # repaints. When there are more values than columns the most recent ones
      # (the tail) are shown.
      #
      # ```
      # bar = Widget::Graph::BlockBar.new parent: s, width: 40, height: 6, max: 100.0
      # s.every(0.2.seconds) { bar.values = cpu_history }
      # ```
      class BlockBar < Box
        # Empty .. full, indexed 0..8 by how many eighths of a cell are filled.
        BLOCKS = " ▁▂▃▄▅▆▇█".chars

        # The data series. Each element is one bar.
        property values : Array(Float64)

        # Bottom of the scale (the baseline a zero-height bar sits at).
        property min : Float64

        # Top of the scale. `nil` auto-scales to the largest shown value each
        # frame; set a fixed value for a stable axis (no jumping).
        property max : Float64?

        def initialize(
          values : Array = [] of Float64,
          @min : Float64 = 0.0,
          @max : Float64? = nil,
          **box,
        )
          @values = values.map(&.to_f)
          super **box
        end

        # Accepts any numeric array, coercing to `Float64`.
        def values=(vals : Array)
          @values = vals.map(&.to_f)
        end

        def render
          self.content = build_content
          super
        end

        # Builds the block-glyph grid for the current size and values.
        private def build_content : String
          cols = awidth - iwidth
          rows = aheight - iheight
          return "" if cols <= 0 || rows <= 0 || @values.empty?

          shown = @values.last(cols)
          top = @max || shown.max
          range = top - @min
          range = 1.0 if range <= 0.0

          # Total filled eighth-cells (0..rows*8) per shown column.
          levels = shown.map do |v|
            norm = ((v - @min) / range).clamp(0.0, 1.0)
            (norm * rows * 8).round.to_i
          end

          String.build do |io|
            rows.times do |r|
              below = rows - 1 - r # cells of bar strictly below this row
              levels.each do |level|
                io << BLOCKS[(level - below * 8).clamp(0, 8)]
              end
              io << '\n' unless r == rows - 1
            end
          end
        end
      end
    end
  end
end
