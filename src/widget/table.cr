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
    #   parent: screen,
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
    # ![Table screenshot](../../examples/widget/table/table-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Table < AbstractItemView
      include TableLayout

      # The table data, as rows of string cells.
      property rows : Array(Array(String))

      # Whether every other body row is painted with `style.alternate_row` instead of
      # `style.cell`, like Qt's `QTableWidget#alternatingRowColors`. Has no
      # visible effect until `style.alternate_row` is given a distinct background.
      property? alternate_rows : Bool = false

      # A table is sized to its content by default.
      @resizable = true

      # The content is pre-formatted into fixed-width columns; it must never be
      # line-wrapped (wrapping a row would push every following row down and
      # desync the cell borders, which is especially visible with wide/CJK
      # cells).
      @wrap_content = false

      # A `Table` is *content-sized*: `#render` pins `@width = row_width + iwidth`
      # so the box always grows to fit every column, and never overflows
      # horizontally. It therefore intentionally opts out of horizontal scrolling
      # — `child_base_x` stays 0, where `_hslice` is a no-op — and a wide table is
      # simply clipped by its parent. For a scrollable wide table use the
      # interactive `Widget::ListTable`, which decouples its width from its
      # content and scrolls by whole columns.

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

        # Pin the width to the exact table width so the box edge lines up with
        # the column positions `#draw_borders` uses. Relying on shrink-to-content
        # alone is not enough: blank separator lines and trailing-space trimming
        # make the measured content width disagree with `@maxes`, which would
        # leave the right border and last column ragged between text and
        # separator rows. Height is still shrunk to the content (`@resizable`).
        # Assigned directly to avoid the `Resize`-before-store recursion that
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
        # Re-pin the size now that the CSS cascade has run (it runs at the top of
        # the screen's `_render`, before any widget renders). `set_data` pins the
        # width at construction/Attach time, but a border arriving via CSS isn't
        # folded into `style` yet then, so `iwidth` would omit the two border
        # columns and leave the box two columns too narrow — the internal
        # separators (drawn against the post-cascade `coords`) would then
        # overshoot the right edge.
        #
        # The height is pinned to the content too: a `Table` is a static,
        # content-sized element (unlike the scrollable `ListTable`), and its
        # cell-border junctions are placed relative to the *content* rows. If the
        # box were taller than the content (e.g. an explicit `height:` larger
        # than the rows need), the box's bottom edge would sit a row below the
        # last junction, leaving a malformed half-drawn separator in the gap. The
        # content is `render_row` lines joined by a blank separator line, so it
        # spans `2*rows - 1` grid rows, plus the top/bottom insets.
        #
        # Both are assigned directly (not via `width=`/`height=`) to avoid the
        # `Resize`-before-store recursion our own `Resize` handler would trigger.
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
        lines = screen.lines
        xi, yi, width, height = border_extent coords

        dattr = sattr style
        hattr = sattr style.header
        cattr = sattr style.cell
        aattr = sattr style.alternate_row
        # Gridlines normally take the box border's attributes; `gridline-color`,
        # when set, overrides just their foreground while keeping the border's
        # background and text attributes.
        battr =
          if gc = style.gridline_color
            sattr style.border, fg: gc, bg: style.border.bg
          else
            sattr style.border
          end

        # Maps each relative text-column x to its table column index (packed by
        # `@maxes`), so CSS per-cell styles (`#css_cell_style`) can override the
        # row default per column.
        col_map = col_for_x(0, ileft)

        # Apply header/cell attributes to text cells that still hold the default
        # attribute (so explicit tags inside cells are preserved).
        y = itop
        while y < height
          if line = lines[yi + y]?
            # Each table row occupies two grid rows (text + separator), so the
            # row index is `(y - itop) // 2`; index 0 is the header. Body rows
            # 2, 4, … (the 2nd, 4th, … data rows) take the alternate attribute.
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
            x = ileft
            while x < width
              if cell = line[xi + x]?
                if cell.attr == dattr
                  # A CSS rule may have computed a style for this specific cell.
                  col = col_map[x]?
                  cell_style = col ? css_cell_style(row_index, col) : nil
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

            # The first column draws the left edge on the box border. This is
            # independent of the last-column handling below so a single-column
            # table (where the first column is also the last) gets both.
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
              # `TableLayout#render_row`), and the box's right border sits one
              # column further still. On an internal separator row, continue the
              # rule across the spare column and place the ┤ junction on the
              # border itself — drawing it on the spare column (as a naive
              # `xi + rx` would) leaves a stray char one short of the border.
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

            # Center junction between this column and the next (also drawn for
            # the first column; never reached for the last column, which
            # returned above).
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
            # Vertical separators between columns.
            draw_vertical_separators line, xi, battr
          else
            # Horizontal rules across cell widths.
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
