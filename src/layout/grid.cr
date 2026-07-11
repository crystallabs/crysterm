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
    #   layout_hint: Layout::Grid::Hint.new(row: 0, col: 0, col_span: 2)
    # Widget::Box.new parent: g # auto-flows into the next free cell
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Grid screenshot](../../tests/layout/grid/grid.5s.apng)
    # <!-- /widget-examples:capture -->
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

      # `#gap` (inter-cell spacing) is inherited from `Layout`.

      # Per-arrange scratch, reused across frames (cleared, not reallocated) so
      # a grid re-render allocates nothing. Transient, not retained past
      # `#arrange`; a layout instance serves a single container.
      @occupied = Set({Int32, Int32}).new
      @placements = [] of Tuple(Widget, Int32, Int32, Int32, Int32)

      def initialize(@columns : Int32 = 2, @rows : Int32? = nil, @gap : Int32 = 0)
      end

      # Caps for degenerate `Grid::Hint` values (see `#arrange`). A row origin
      # is clamped to `ROW_ORIGIN_CAP` so the checked adds in the row inference
      # (`p[1] + 1`, `p[1] + p[3]`) can't raise `OverflowError` on
      # `row: Int32::MAX`. Occupancy bookkeeping never records rows past
      # `OCCUPANCY_ROW_CAP`: `#occupy` iterates the span, so a raw
      # `row_span: Int32::MAX` would insert 2^31 tuples into the occupancy set
      # on every arrange (every frame) — a permanent render-fiber stall.
      # Placement geometry is unaffected by either cap: `#fence` clamps every
      # cell to the real grid regardless.
      ROW_ORIGIN_CAP    = 1_000_000
      OCCUPANCY_ROW_CAP =      4096

      def arrange(container : Widget, interior : LPos) : Nil
        w = interior.xl - interior.xi
        h = interior.yl - interior.yi
        cols = Math.max(@columns, 1)

        occupied = @occupied
        occupied.clear
        # {widget, row, col, row_span, col_span}
        placements = @placements
        placements.clear

        # Explicitly-placed children first, so auto-flow can skip their cells.
        # Hints are clamped to grid bounds before any bookkeeping (see the
        # caps above): column origin/span to the fixed `columns`; the row
        # origin to `ROW_ORIGIN_CAP`. The row *span* is clamped against
        # `row_bound` below, once every explicit origin is known — preserving
        # the file's "an over-large span spans to the end" semantics while
        # keeping `#occupy` (which iterates the span) proportional to real
        # grid cells rather than to `Int32::MAX`.
        max_origin = 0
        total = 0
        each_arrangeable container do |el|
          total += 1
          next unless hint = el.layout_hint.as?(Hint)
          row = hint.row.clamp(0, ROW_ORIGIN_CAP)
          col = hint.col.clamp(0, cols)
          rs = Math.max(hint.row_span, 1)
          cs = hint.col_span.clamp(1, Math.max(cols - col, 1))
          placements << {el, row, col, rs, cs}
          max_origin = Math.max(max_origin, row)
        end

        # The deepest row bookkeeping can meaningfully reach: the declared
        # `rows`, or the row inference's own upper bound (content origins plus
        # one row per arrangeable child — `nrows` below can never exceed it),
        # hard-capped so degenerate input can't make occupancy per-frame work
        # unbounded. Spans are stored clamped, so the inference's `p[1] + p[3]`
        # also sees the clamped values.
        row_bound = Math.min(@rows || (max_origin + 1 + total), OCCUPANCY_ROW_CAP)
        row_bound = 1 if row_bound < 1
        placements.map! do |placement|
          el, row, col, rs, cs = placement
          rs = Math.min(rs, Math.max(row_bound - row, 1))
          occupy occupied, row, col, rs, cs
          {el, row, col, rs, cs}
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

        # Row count. When `rows` is given, use it. Otherwise infer from the
        # placements — but unlike the column axis (whose count is the fixed
        # `columns`, so an over-large `col_span: 99` "span to the end" is simply
        # clamped to the last column by `#fence`), the row axis has no fixed
        # bound to clamp an over-large `row_span` against. Taken literally,
        # `p[1] + p[3]` would let a single `row_span: 99` inflate the grid to 99
        # rows, squeezing every cell to nothing and driving `inner_h` negative
        # once gaps are subtracted — collapsing the whole grid.
        #
        # So cap the inferred count at the rows that actually hold content: the
        # deeper of the rows reached by child *origins* (`p[1] + 1`) and the
        # child count (an upper bound on distinct rows). An over-large span then
        # spans to the last real row via `#fence`'s clamp, making `row_span: 99`
        # behave symmetrically to `col_span: 99` as "span to the last row".
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

        # Interior space the cells share, with inter-cell gaps removed.
        # Columns/rows are carved out by *cumulative* integer division (see
        # #fence) rather than a single floored `cell_w`/`cell_h`: a uniform
        # floor would drop up to `cols - 1` columns (and `nrows - 1` rows) of
        # remainder as blank space at the right/bottom edge. Cumulative fences
        # make column widths differ by at most one and sum to exactly
        # `inner_w`, the last column/row absorbing the remainder — matching
        # how Box/Form hand their leftover to the final cell.
        inner_w = w - (cols - 1) * @gap
        inner_h = h - (nrows - 1) * @gap
        inner_w = 0 if inner_w < 0
        inner_h = 0 if inner_h < 0

        placements.each do |(el, row, col, rs, cs)|
          # Clamp the cell's start/end *to the grid* before deriving the gap
          # terms. `#fence` already clamps the pixel fences, but gap
          # multipliers using the raw span/start would add phantom inter-cell
          # gaps for an off-grid span (e.g. `col_span: 99` "span to the end"),
          # pushing the cell's edge past the interior. Counting gaps from the
          # on-grid extent keeps in-grid cells unaffected while making
          # off-grid spans truly stop at the edge.
          c0 = col.clamp(0, cols)
          c1 = (col + cs).clamp(0, cols)
          r0 = row.clamp(0, nrows)
          r1 = (row + rs).clamp(0, nrows)
          x0 = fence inner_w, cols, c0
          x1 = fence inner_w, cols, c1
          y0 = fence inner_h, nrows, r0
          y1 = fence inner_h, nrows, r1
          col_gaps = c1 > c0 ? c1 - c0 - 1 : 0
          row_gaps = r1 > r0 ? r1 - r0 - 1 : 0
          el.left = x0 + c0 * @gap
          el.top = y0 + r0 * @gap
          el.width = (x1 - x0) + col_gaps * @gap
          el.height = (y1 - y0) + row_gaps * @gap
          render_child el
        end
      end

      # Cumulative offset of fence line `i` when `total` is divided into `n`
      # equal-as-possible parts: `floor(i * total / n)`. Successive fences give
      # each cell `fence(i+1) - fence(i)`, summing to exactly `total` with the
      # last absorbing the remainder. `i` clamped to `0..n` so an off-grid
      # span (`col + col_span > columns`) stops at the interior edge.
      private def fence(total : Int32, n : Int32, i : Int32) : Int32
        i = i.clamp(0, n)
        (i * total) // n
      end

      # Advances the row-major auto-flow cursor to the next cell, wrapping to
      # the start of the next row once past the last column. Shared by the
      # free-cell scan and the post-placement step.
      private def next_cell(r : Int32, c : Int32, cols : Int32) : Tuple(Int32, Int32)
        c += 1
        if c >= cols
          c = 0
          r += 1
        end
        {r, c}
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
