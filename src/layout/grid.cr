require "./layout"

module Crysterm
  class Layout
    # A real row × column grid (Qt's `QGridLayout`, Tk's `grid`, CSS Grid) —
    # distinct from `Layout::UniformGrid`, which is a uniform-width *wrapping
    # flow*. Children are placed into the cells of a `columns`-wide grid: either
    # explicitly via a `Grid::Hint` (with optional row/column spans) or
    # auto-flowed row-major into the free cells. Columns and rows divide the
    # interior evenly (minus `gap`); the row count is taken from `rows` or
    # inferred from placement.
    #
    # ```
    # g = Widget::Box.new parent: screen, width: "100%", height: "100%",
    #   layout: Layout::Grid.new(columns: 3, gap: 1)
    # Widget::Box.new parent: g,
    #   layout_hint: Layout::Grid::Hint.new(row: 0, col: 0, col_span: 2)
    # Widget::Box.new parent: g   # auto-flows into the next free cell
    # ```
    class Grid < Layout
      class Hint < Layout::Hint
        getter row : Int32
        getter col : Int32
        getter row_span : Int32
        getter col_span : Int32

        def initialize(@row : Int32, @col : Int32, @row_span : Int32 = 1, @col_span : Int32 = 1)
        end
      end

      property columns : Int32
      property rows : Int32?
      property gap : Int32

      def initialize(@columns : Int32 = 2, @rows : Int32? = nil, @gap : Int32 = 0)
      end

      def arrange(container : Widget, interior : LPos) : Nil
        w = interior.xl - interior.xi
        h = interior.yl - interior.yi
        cols = Math.max(@columns, 1)

        occupied = Set({Int32, Int32}).new
        # {widget, row, col, row_span, col_span}
        placements = [] of Tuple(Widget, Int32, Int32, Int32, Int32)
        auto = [] of Widget

        # Explicitly-placed children first, so auto-flow can skip their cells.
        container.children.each do |el|
          if hint = el.layout_hint.as?(Hint)
            rs = Math.max(hint.row_span, 1)
            cs = Math.max(hint.col_span, 1)
            placements << {el, hint.row, hint.col, rs, cs}
            occupy occupied, hint.row, hint.col, rs, cs
          else
            auto << el
          end
        end

        # Auto-flow the rest into free cells, row-major.
        r = 0
        c = 0
        auto.each do |el|
          while occupied.includes?({r, c})
            c += 1
            if c >= cols
              c = 0
              r += 1
            end
          end
          placements << {el, r, c, 1, 1}
          occupied << {r, c}
          c += 1
          if c >= cols
            c = 0
            r += 1
          end
        end

        nrows = @rows || (placements.map { |p| p[1] + p[3] }.max? || 0)
        nrows = 1 if nrows < 1

        cell_w = (w - (cols - 1) * @gap) // cols
        cell_h = (h - (nrows - 1) * @gap) // nrows
        cell_w = 0 if cell_w < 0
        cell_h = 0 if cell_h < 0

        placements.each do |(el, row, col, rs, cs)|
          el.left = col * (cell_w + @gap)
          el.top = row * (cell_h + @gap)
          el.width = cs * cell_w + (cs - 1) * @gap
          el.height = rs * cell_h + (rs - 1) * @gap
          render_child el
        end
      end

      private def occupy(occupied, row, col, rs, cs)
        rs.times do |dr|
          cs.times do |dc|
            occupied << {row + dr, col + dc}
          end
        end
      end
    end
  end
end
