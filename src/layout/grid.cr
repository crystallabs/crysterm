require "../layout"

module Crysterm
  class Layout
    # A real row × column grid (Qt's `QGridLayout`, Tk's `grid`, CSS Grid) —
    # distinct from `Layout::UniformGrid`, which is a uniform-width *wrapping
    # flow*. Children are placed into the cells of a `columns`-wide grid: either
    # explicitly via a `Grid::Hint` (with optional row/column spans) or
    # auto-flowed row-major into the free cells. Columns and rows divide the
    # interior evenly (minus `spacing`); the row count is taken from `rows` or
    # inferred from placement.
    #
    # ```
    # g = Widget::Box.new parent: window, width: "100%", height: "100%",
    #   layout: Layout::Grid.new(columns: 3, spacing: 1)
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
        property row : Int32
        property column : Int32
        property row_span : Int32
        property column_span : Int32

        def initialize(@row : Int32, @column : Int32, @row_span : Int32 = 1, @column_span : Int32 = 1)
        end
      end

      # Number of columns; change-guarded so a real change repaints the container.
      @columns : Int32

      # :ditto:
      def columns : Int32
        @columns
      end

      # :ditto:
      def columns=(value : Int32) : Int32
        return value if value == @columns
        @columns = value
        invalidate
        value
      end

      # Fixed row count, or `nil` to infer from placement; change-guarded so a real
      # change repaints the container.
      @rows : Int32?

      # :ditto:
      def rows : Int32?
        @rows
      end

      # :ditto:
      def rows=(value : Int32?) : Int32?
        return value if value == @rows
        @rows = value
        invalidate
        value
      end

      # `#spacing` (inter-cell spacing) is inherited from `Layout`.

      # Per-arrange scratch, cleared rather than reallocated so a re-render
      # allocates nothing. Not retained past `#arrange`.
      @occupied = Set({Int32, Int32}).new
      @placements = [] of Tuple(Widget, Int32, Int32, Int32, Int32)

      def initialize(@columns : Int32 = 2, @rows : Int32? = nil, @spacing : Int32 = 0)
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
        w = interior.width
        h = interior.height
        # Cap axis counts at the interior extent, not just `1`: any column/row
        # past the interior is a zero-size cell already, so this is
        # behavior-preserving, and it keeps `cols`/`nrows` small enough that
        # the spacing/fence math below can't overflow `Int32`.
        cols = @columns.clamp(1, Math.max(w, 1))

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
        # Row-origin cap: with a declared `rows` clamp to the *last* valid row —
        # like the column axis below, so an off-grid row origin stays visible
        # instead of collapsing to a zero-height cell past the bottom edge.
        # Without a declared `rows` the count is inferred, so the origin may
        # extend the grid and only the overflow-guard cap applies.
        row_origin_cap =
          if (r = @rows) && r > 0
            Math.min(ROW_ORIGIN_CAP, r - 1)
          elsif @rows
            0
          else
            ROW_ORIGIN_CAP
          end
        each_arrangeable container do |el|
          total += 1
          next unless hint = el.layout_hint.as?(Hint)
          row = hint.row.clamp(0, row_origin_cap)
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
          # Same reasoning as `cols` above: a declared `rows` past the
          # interior height is all zero-size cells, so capping it there is
          # behavior-preserving and keeps the spacing math below overflow-safe.
          nrows = r.clamp(1, Math.max(h, 1))
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
        # `cols`/`nrows` are now capped to the interior extent, but `@spacing`
        # itself is not: a pathological spacing still overflows `Int32` here,
        # so the gap term runs in `Int64` and the result clamps back to
        # `0..w`/`0..h` (a negative raw result already meant "no room left").
        inner_w = (w.to_i64 - (cols - 1).to_i64 * @spacing).clamp(0_i64, w.to_i64).to_i32
        inner_h = (h.to_i64 - (nrows - 1).to_i64 * @spacing).clamp(0_i64, h.to_i64).to_i32

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
          # Reserve the child's margin box, mirroring Layout::Box's stretch
          # branch: `_get_coords` shifts a fixed-size box outward by its near
          # margin without shrinking it, so a raw cell-sized child would paint
          # its margin past the cell's far edge into the neighbour (or past the
          # container for a last-column/row cell). Subtracting the margin sums
          # keeps the shifted box inside its cell.
          #
          # `c0`/`col_gaps` (resp. `r0`/`row_gaps`) are bounded by `cols`
          # (resp. `nrows`), which are now capped to the interior, but a
          # pathological `@spacing` still overflows `Int32` in these products,
          # so each offset/size runs in `Int64` and clamps back to the
          # interior it can never legitimately exceed.
          el.left = (x0.to_i64 + c0.to_i64 * @spacing).clamp(0_i64, w.to_i64).to_i32
          el.top = (y0.to_i64 + r0.to_i64 * @spacing).clamp(0_i64, h.to_i64).to_i32
          el.width = ((x1.to_i64 - x0.to_i64) + col_gaps.to_i64 * @spacing - el.mhorizontal).clamp(0_i64, w.to_i64).to_i32
          el.height = ((y1.to_i64 - y0.to_i64) + row_gaps.to_i64 * @spacing - el.mvertical).clamp(0_i64, h.to_i64).to_i32
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
