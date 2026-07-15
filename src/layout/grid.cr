require "../layout"

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
    # g = Widget::Box.new parent: window, width: "100%", height: "100%",
    #   layout: Layout::Grid.new(columns: 3, gap: 1)
    # Widget::Box.new parent: g,
    #   layout_hint: Layout::Grid::Hint.new(row: 0, column: 0, column_span: 2)
    # Widget::Box.new parent: g # auto-flows into the next free cell
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Grid screenshot](../../tests/layout/grid/grid.5s.apng)
    # <!-- /widget-examples:capture -->
    class Grid < Layout
      class Hint < Layout::Hint
        getter row : Int32
        getter column : Int32
        getter row_span : Int32
        getter column_span : Int32

        def initialize(@row : Int32, @column : Int32, @row_span : Int32 = 1, @column_span : Int32 = 1)
        end
      end

      property columns : Int32
      property rows : Int32?

      # `#gap` (inter-cell spacing) is inherited from `Layout`.

      # Per-arrange scratch, cleared rather than reallocated so a re-render
      # allocates nothing. Not retained past `#arrange`.
      @occupied = Set({Int32, Int32}).new
      @placements = [] of Tuple(Widget, Int32, Int32, Int32, Int32)

      def initialize(@columns : Int32 = 2, @rows : Int32? = nil, @gap : Int32 = 0)
      end

      # Caps for degenerate `Grid::Hint` values. A row origin is clamped to
      # `ROW_ORIGIN_CAP` so the checked adds in the row inference can't overflow
      # on `row: Int32::MAX`. Occupancy never records rows past
      # `OCCUPANCY_ROW_CAP`: `#occupy` iterates the span, so `row_span:
      # Int32::MAX` would insert 2^31 tuples per frame — a render-fiber stall.
      # Placement geometry is unaffected: `Layout.fence` clamps every cell to the
      # real grid regardless.
      ROW_ORIGIN_CAP    = 1_000_000
      OCCUPANCY_ROW_CAP =      4096

      def arrange(container : Widget, interior : RenderedGeometry) : Nil
        w = interior.xl - interior.xi
        h = interior.yl - interior.yi
        cols = Math.max(@columns, 1)

        occupied = @occupied
        occupied.clear
        # {widget, row, column, row_span, column_span}
        placements = @placements
        placements.clear

        # Explicitly-placed children first, so auto-flow can skip their cells.
        # Hints are clamped to grid bounds before any bookkeeping: column
        # origin/span to `columns`, the row origin to `ROW_ORIGIN_CAP`. The row
        # *span* is clamped against `row_bound` below, once every explicit origin
        # is known.
        max_origin = 0
        total = 0
        each_arrangeable container do |el|
          total += 1
          next unless hint = el.layout_hint.as?(Hint)
          row = hint.row.clamp(0, ROW_ORIGIN_CAP)
          # Clamp to the *last* valid column, not `cols`: an origin of `cols`
          # collapses the cell to zero width past the right edge, vanishing —
          # asymmetric with a negative `column`, which clamps to 0 and stays
          # visible.
          column = hint.column.clamp(0, cols - 1)
          rs = Math.max(hint.row_span, 1)
          cs = hint.column_span.clamp(1, Math.max(cols - column, 1))
          placements << {el, row, column, rs, cs}
          max_origin = Math.max(max_origin, row)
        end

        # The deepest row bookkeeping can meaningfully reach: the declared `rows`,
        # or the row inference's own upper bound, hard-capped so degenerate input
        # can't make per-frame occupancy work unbounded.
        row_bound = Math.min(@rows || (max_origin + 1 + total), OCCUPANCY_ROW_CAP)
        row_bound = 1 if row_bound < 1
        placements.map! do |placement|
          el, row, column, rs, cs = placement
          rs = Math.min(rs, Math.max(row_bound - row, 1))
          occupy occupied, row, column, rs, cs
          {el, row, column, rs, cs}
        end

        # Auto-flow the rest (children with no Hint) into free cells, row-major.
        r = 0
        c = 0
        each_arrangeable container do |el|
          next if el.layout_hint.is_a?(Hint)
          while occupied.includes?({r, c})
            r, c = next_cell r, c, cols
          end
          placements << {el, r, c, 1, 1}
          occupied << {r, c}
          r, c = next_cell r, c, cols
        end

        # Row count: the declared `rows`, else inferred. Unlike the column axis
        # (bounded by the fixed `columns`), the row axis has no natural bound, so
        # a lone `row_span: 99` taken literally would inflate the grid to 99 rows
        # and collapse it. Cap the inferred count at the rows that actually hold
        # content, so an over-large span spans to the last real row — symmetric
        # with `column_span`.
        if r = @rows
          nrows = r
        else
          start_rows = 0
          span_rows = 0
          placements.each do |p|
            start_rows = Math.max(start_rows, p[1] + 1)
            span_rows = Math.max(span_rows, p[1] + p[3])
          end
          nrows = Math.min(span_rows, Math.max(start_rows, placements.size))
        end
        nrows = 1 if nrows < 1

        # Interior space the cells share, with inter-cell gaps removed. Cells are
        # carved by *cumulative* integer division (`Layout.fence`), so widths
        # differ by at most one and sum to exactly `inner_w`; a uniform floored
        # `cell_w` would strand the remainder as blank space at the far edge.
        inner_w = w - (cols - 1) * @gap
        inner_h = h - (nrows - 1) * @gap
        inner_w = 0 if inner_w < 0
        inner_h = 0 if inner_h < 0

        placements.each do |(el, row, column, rs, cs)|
          # Clamp the cell's start/end *to the grid* before deriving the gap
          # terms: gap multipliers taken from a raw off-grid span would add
          # phantom gaps and push the cell past the interior.
          c0 = column.clamp(0, cols)
          c1 = (column + cs).clamp(0, cols)
          r0 = row.clamp(0, nrows)
          r1 = (row + rs).clamp(0, nrows)
          x0 = Layout.fence inner_w, cols, c0
          x1 = Layout.fence inner_w, cols, c1
          y0 = Layout.fence inner_h, nrows, r0
          y1 = Layout.fence inner_h, nrows, r1
          col_gaps = c1 > c0 ? c1 - c0 - 1 : 0
          row_gaps = r1 > r0 ? r1 - r0 - 1 : 0
          el.left = x0 + c0 * @gap
          el.top = y0 + r0 * @gap
          el.width = (x1 - x0) + col_gaps * @gap
          el.height = (y1 - y0) + row_gaps * @gap
          render_child el
        end
      end

      # Advances the row-major auto-flow cursor to the next cell, wrapping to the
      # start of the next row once past the last column.
      private def next_cell(r : Int32, c : Int32, cols : Int32) : Tuple(Int32, Int32)
        c += 1
        if c >= cols
          c = 0
          r += 1
        end
        {r, c}
      end

      private def occupy(occupied, row, column, rs, cs)
        rs.times do |dr|
          cs.times do |dc|
            occupied << {row + dr, column + dc}
          end
        end
      end
    end
  end
end
