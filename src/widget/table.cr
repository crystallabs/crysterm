require "./abstract_item_view"
require "../widget_table_layout"

module Crysterm
  class Widget
    # Static table element.
    #
    # Renders a grid of cells (`rows`) with aligned columns and, optionally,
    # line-drawing borders between cells. Unlike `Widget::ListTable`, a `Table`
    # is not interactive — it is purely for display.
    #
    # ```
    # Widget::Table.new(
    #   parent: window,
    #   rows: [
    #     ["Name", "Email"],
    #     ["Alice", "alice@example.com"],
    #     ["Bob", "bob@example.com"],
    #   ],
    #   style: Crysterm::Style.new(border: true)
    # )
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Table screenshot](../../tests/widget/table/table.5s.apng)
    # <!-- /widget-examples:capture -->
    class Table < AbstractItemView
      include TableLayout

      # The table data, as rows of string cells.
      property rows : Array(Array(String))

      # Whether every other body row is painted with `style.alternate_row` instead
      # of `style.cell`. No visible effect until `style.alternate_row` gets a
      # distinct background.
      property? alternate_rows : Bool = false

      # A table is sized to its content by default.
      @resizable = true

      # Content is pre-formatted into fixed-width columns; must never be
      # line-wrapped (would push following rows down and desync cell borders,
      # especially visible with wide/CJK cells).
      @wrap_content = false

      # A `Table` is content-sized: `#render` pins `@width` so the box always fits
      # every column and never overflows horizontally. It opts out of horizontal
      # scrolling entirely (`child_base_x` stays 0) — a wide table is just clipped
      # by its parent. For a scrollable wide table use `Widget::ListTable` instead.

      # Cached x→column map used by `#draw_borders` to resolve a CSS per-cell
      # style from a window column. Depends only on `@maxes`/`ileft`, but
      # `draw_borders` runs every frame, so this avoids rebuilding the `Hash` each
      # time. Rebuilt only when `@maxes` or `ileft` changes.
      @border_col_map : Hash(Int32, Int32)? = nil
      @border_col_map_maxes : Array(Int32)? = nil
      @border_col_map_ileft : Int32 = -1

      private def border_col_map : Hash(Int32, Int32)
        cached = @border_col_map
        if cached.nil? || !@maxes.same?(@border_col_map_maxes) || ileft != @border_col_map_ileft
          cached = @border_col_map = col_for_x(0, ileft)
          @border_col_map_maxes = @maxes
          @border_col_map_ileft = ileft
        end
        cached
      end

      # Reused scratch set: rows that carry a CSS-computed cell style this frame
      # (`#draw_borders` repopulates it from `@css_cells`). Default theme styles
      # only row 0 (Header), so an otherwise-unstyled table lets every body row
      # skip per-cell CSS lookups.
      @styled_rows = Set(Int32).new

      def initialize(
        rows = nil,
        data = nil,
        pad = nil,
        no_cell_borders = nil,
        fill_cell_borders = nil,
        alternate_rows = false,
        *,
        align : Tput::AlignFlag | Shorthands = Tput::AlignFlag::Center,
        **box,
      )
        @rows = normalize_rows(rows || data)
        @alternate_rows = alternate_rows
        self.cell_align = align
        init_cell_options pad, no_cell_borders, fill_cell_borders

        super **box

        set_data @rows

        on(Crysterm::Event::Attach) { set_data @rows }
        on(Crysterm::Event::Resize) do
          set_data @rows
          request_render
        end
      end

      # :ditto:
      def set_rows(rows)
        set_data rows
      end

      # Replaces the table data and rebuilds the rendered content.
      def set_data(rows)
        return unless reload_rows rows

        # Pin width to the exact table width so the box edge lines up with the
        # column positions `#draw_borders` uses. Shrink-to-content alone isn't
        # enough: blank separator lines and trailing-space trimming make the
        # measured content width disagree with `@maxes`, leaving the right border
        # ragged. Assigned directly to avoid the `Resize`-before-store recursion
        # `width=` would trigger via our own `Resize` handler.
        @width = row_width + iwidth

        text = String.build do |str|
          @rows.each_with_index do |row, ri|
            is_footer = ri == @rows.size - 1
            str << render_row(row)
            str << "\n\n" unless is_footer
          end
        end

        set_content text
      end

      def render(with_children = true)
        # Re-pin the size now that the CSS cascade has run. `set_data` pins width
        # at construction/Attach time, but a border arriving via CSS isn't folded
        # into `style` yet then, so `iwidth` would omit the border columns and
        # leave internal separators overshooting the right edge.
        #
        # Height is pinned too: cell-border junctions are placed relative to the
        # content rows, so a taller box (e.g. explicit `height:`) would leave a
        # malformed half-drawn separator below the last junction. Content spans
        # `2*rows - 1` grid rows (render_row lines + blank separators) plus insets.
        #
        # Both assigned directly to avoid the `Resize`-before-store recursion our
        # own `Resize` handler would trigger.
        calculate_maxes
        unless @maxes.empty?
          @width = row_width + iwidth
          @height = Math.max(0, 2 * @rows.size - 1) + iheight
        end

        coords = super
        return coords unless coords

        return coords if @maxes.empty?

        draw_borders coords
        coords
      end

      # Recolors header/cell text and draws the internal cell borders. Ported
      # from Blessed's `Table.prototype.render`, adapted to Crysterm's cell grid.
      # ameba:disable Metrics/CyclomaticComplexity
      private def draw_borders(coords)
        lines = window.lines
        xi, yi, width, height = border_extent coords

        dattr = sattr style
        hattr = sattr style.header
        cattr = sattr style.cell
        aattr = sattr style.alternate_row
        # `gridline-color`, when set, overrides just the gridlines' foreground
        # while keeping the border's background/text attributes.
        battr =
          if gc = style.gridline_color
            sattr style.border, fg: gc, bg: style.border.bg
          else
            sattr style.border
          end

        # Maps each relative text-column x to its table column index, so CSS
        # per-cell styles (`#css_cell_style`) can override the row default. Built
        # (cached, see `#border_col_map`) only when CSS per-cell rules exist,
        # since a plain table re-renders every frame. `@styled_rows` lets unstyled
        # rows skip per-cell lookups entirely (~20x faster on an unstyled table).
        @styled_rows.clear
        col_map = if (cc = @css_cells) && !cc.empty?
                    cc.each_key { |(r, _)| @styled_rows << r }
                    border_col_map
                  end

        # Apply header/cell attributes to text cells that still hold the default
        # attribute (so explicit tags inside cells are preserved).
        y = itop
        while y < height
          if line = lines[yi + y]?
            # Each table row occupies two grid rows (text + separator); row index
            # is `(y - itop) // 2`, with index 0 the header. Body rows 2, 4, …
            # take the alternate attribute.
            offset = y - itop
            row_index = offset // 2
            default_attr =
              if offset.even? && row_index == 0
                hattr
              elsif offset.even? && alternate_rows? && row_index.even?
                aattr
              else
                cattr
              end
            # CSS cell overrides only exist on styled rows; skip the per-cell
            # `col_map`/`css_cell_style` lookups for every other row.
            row_map = col_map.try { |cm| @styled_rows.includes?(row_index) ? cm : nil }
            x = ileft
            while x < width
              if cell = line[xi + x]?
                if cell.attr == dattr
                  cell_style = if rm = row_map
                                 (col = rm[x]?) ? css_cell_style(row_index, col) : nil
                               end
                  cell.attr = cell_style ? sattr(cell_style) : default_attr
                  line.dirty = true
                end
              else
                break
              end
              x += 1
            end
          else
            break
          end
          y += 1
        end

        border = style.border
        return if !border.any? || no_cell_borders?

        rows_n = @rows.size
        last = @maxes.size - 1

        # Draw border junctions row by row (each table row spans two grid rows).
        ry = 0
        (rows_n + 1).times do
          line = lines[yi + ry]?
          break unless line

          rx = 0
          @maxes.each_with_index do |max, mi|
            rx += max

            # First column draws the left edge on the box border, independent of
            # the last-column handling below, so a single-column table gets both.
            if mi == 0
              if cell = line[xi + 0]?
                cell.attr = battr
                if ry != 0 && (ry // 2) != rows_n
                  cell.char = border.left > 0 ? '├' : '─'
                end
                line.dirty = true
              end
            end

            if mi == last
              # The last cell is followed by a trailing spare column (see
              # `TableLayout#render_row`), with the box's right border one column
              # further. On an internal separator row, continue the rule across
              # the spare column and place ┤ on the border itself — a naive
              # `xi + rx` would leave a stray char short of the border.
              internal = ry != 0 && (ry // 2) != rows_n
              if cell = line[xi + rx + 1]?
                rx += 1
                cell.attr = battr
                cell.char = '─' if internal
                line.dirty = true
              end
              if internal && (cell = line[xi + rx + 1]?)
                cell.attr = battr
                cell.char = border.right > 0 ? '┤' : '─'
                line.dirty = true
              end
              next
            end

            # Center junction between this column and the next (never reached for
            # the last column, which returned above).
            next unless line[xi + rx + 1]?
            rx += 1
            if cell = line[xi + rx]?
              if ry == 0
                cell.attr = battr
                cell.char = border.top > 0 ? '┬' : '│'
              elsif (ry // 2) == rows_n
                cell.attr = battr
                cell.char = border.bottom > 0 ? '┴' : '│'
              else
                cell.attr = junction_attr(battr, ry <= 2 ? hattr : cattr)
                cell.char = '┼'
              end
              line.dirty = true
            end
          end

          ry += 2
        end

        # Draw internal horizontal/vertical border runs.
        ry = 1
        while ry < rows_n * 2
          line = lines[yi + ry]?
          break unless line

          if ry.odd?
            draw_vertical_separators line, xi, battr
          else
            rx = 1
            @maxes.each do |max|
              max.times do
                break unless line[xi + rx + 1]?
                if cell = line[xi + rx]?
                  cell.attr = junction_attr(battr, cell.attr)
                  cell.char = '─'
                  line.dirty = true
                end
                rx += 1
              end
              rx += 1
            end
          end

          ry += 1
        end
      end
    end
  end
end
