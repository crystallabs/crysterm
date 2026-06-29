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
    # ![Grid screenshot](../../examples/layout/grid/grid-capture5s.apng)
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

      # Per-arrange scratch, reused across frames (cleared, not reallocated) so a
      # grid re-render allocates nothing — `Set#clear`/`Array#clear` keep their
      # capacity. Transient and not retained past `#arrange`; a layout instance
      # serves a single container.
      @occupied = Set({Int32, Int32}).new
      @placements = [] of Tuple(Widget, Int32, Int32, Int32, Int32)

      def initialize(@columns : Int32 = 2, @rows : Int32? = nil, @gap : Int32 = 0)
      end

      def arrange(container : Widget, interior : LPos) : Nil
        w = interior.xl - interior.xi
        h = interior.yl - interior.yi
        cols = Math.max(@columns, 1)

        occupied = @occupied
        occupied.clear
        # {widget, row, col, row_span, col_span}. The tuples live inline in the
        # array's buffer (value types, no per-element heap box).
        placements = @placements
        placements.clear

        # Explicitly-placed children first, so auto-flow can skip their cells.
        each_arrangeable container do |el|
          next unless hint = el.layout_hint.as?(Hint)
          rs = Math.max(hint.row_span, 1)
          cs = Math.max(hint.col_span, 1)
          placements << {el, hint.row, hint.col, rs, cs}
          occupy occupied, hint.row, hint.col, rs, cs
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

        # Tallest occupied row index, without the intermediate array a
        # `placements.map { … }.max?` would allocate. `reduce(0)` also yields the
        # old `|| 0` for an empty grid.
        nrows = @rows || placements.reduce(0) { |m, p| Math.max(m, p[1] + p[3]) }
        nrows = 1 if nrows < 1

        # Interior space the cells share, with the inter-cell gaps removed. The
        # columns/rows are carved out of this by *cumulative* integer division
        # (see #fence) rather than a single floored `cell_w`/`cell_h`: a uniform
        # floor dropped up to `cols - 1` columns (and `nrows - 1` rows) of
        # remainder, leaving them blank at the right/bottom edge so the grid
        # never filled a non-evenly-divisible interior. Carving by cumulative
        # fences makes the column widths differ by at most one and sum to exactly
        # `inner_w`, with the last column/row absorbing the remainder — matching
        # how Box/Form hand their leftover to the final cell.
        inner_w = w - (cols - 1) * @gap
        inner_h = h - (nrows - 1) * @gap
        inner_w = 0 if inner_w < 0
        inner_h = 0 if inner_h < 0

        placements.each do |(el, row, col, rs, cs)|
          # Clamp the cell's start/end *to the grid* before deriving the gap
          # terms. `#fence` already clamps the pixel fences, so the off-grid part
          # of a span contributes no width — but the gap multipliers below used
          # the raw span (`cs`/`rs`) and the raw start (`col`/`row`), so an
          # off-grid span (e.g. the common `col_span: 99` "span to the end"
          # idiom) added `(cs - on_grid_cols)` phantom inter-cell gaps, shoving
          # the cell's right/bottom edge well past the interior — defeating the
          # very edge-clamp `#fence` documents. Counting gaps from the on-grid
          # extent keeps in-grid cells byte-identical (for them `c0..c1` == the
          # raw span) while making off-grid spans truly stop at the edge.
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

      # The cumulative offset of fence line `i` when `total` is divided into `n`
      # equal-as-possible parts: `floor(i * total / n)`. Successive fences give
      # each cell `fence(i+1) - fence(i)` (so the parts sum to exactly `total`,
      # the last absorbing the remainder). `i` is clamped to `0..n` so an
      # off-grid span (`col + col_span > columns`) stops at the interior edge
      # instead of running past it.
      private def fence(total : Int32, n : Int32, i : Int32) : Int32
        i = i.clamp(0, n)
        (i * total) // n
      end

      # Advances the row-major auto-flow cursor to the next cell, wrapping to the
      # start of the next row once it runs past the last column. Returns the new
      # `{row, col}` as a value tuple (no heap allocation). Shared by the free-cell
      # scan and the post-placement step, which advance the cursor identically.
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
