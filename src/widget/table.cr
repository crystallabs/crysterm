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

      # The table data, as rows of string cells. Read-only; assign through
      # `#rows=`, which rebuilds the view.
      getter rows : Array(Array(String))

      # Whether every other body row is painted with `style.alternate_row` instead
      # of `style.cell`. No visible effect until `style.alternate_row` gets a
      # distinct background.
      property? alternate_rows : Bool = false

      # A table is sized to its content by default.
      @shrink_to_fit = true

      # Content is pre-formatted into fixed-width columns; must never be
      # line-wrapped (would push following rows down and desync cell borders,
      # especially visible with wide/CJK cells).
      @wrap_content = false

      # A `Table` is content-sized: `#render` pins `@width` so the box always fits
      # every column and never overflows horizontally. It opts out of horizontal
      # scrolling entirely (`child_base_x` stays 0) — a wide table is just clipped
      # by its parent. For a scrollable wide table use `Widget::ListTable` instead.

      # NOTE: there is deliberately no `data:` parameter. It used to be a second
      # spelling of `rows:`, on a widget that *also* inherits an unrelated
      # `Widget#data` (`Mixin::Data`'s `YAML::Any?` slot) — so `Table.new(data:
      # rows)` set the rows while `table.data = x` set the YAML. Pass `rows:`.
      # (`Widget::Pine::SelectableList` documents dodging the same collision by
      # naming its array `records`.)
      def initialize(
        rows = nil,
        pad = nil,
        no_cell_borders = nil,
        fill_cell_borders = nil,
        alternate_rows = false,
        *,
        align : Tput::AlignFlag | Shorthands = Tput::AlignFlag::Center,
        **box,
      )
        @rows = normalize_rows(rows)
        @alternate_rows = alternate_rows
        self.cell_align = align
        init_cell_options pad, no_cell_borders, fill_cell_borders

        super **box

        self.rows = @rows

        on(Crysterm::Event::Attach) { self.rows = @rows }
        on(Crysterm::Event::Resize) do
          self.rows = @rows
          request_render
        end
      end

      # Replaces the table data and rebuilds the rendered content.
      #
      # A real setter, not the one `property rows` used to generate: that one
      # assigned `@rows` and stopped, bypassing `#reload_rows` — so `@maxes_dirty`
      # was never set and the column widths, the pinned `@width` and the rendered
      # content all kept describing the OLD data, while `#render` went on sizing
      # the box's height from the NEW `@rows.size`. The working path was
      # `set_data`/`set_rows`; both are folded in here, since one argument is one
      # argument and `rows=` is how Crystal spells it.
      def rows=(rows)
        unless reload_rows rows
          # Empty/column-less data must empty the view too: `reload_rows` has
          # already replaced `@rows`, so returning with the old content rendered
          # would show rows the model no longer holds.
          set_content ""
          return
        end

        # Pin width to the exact table width so the box edge lines up with the
        # column positions `#draw_borders` uses. Shrink-to-content alone isn't
        # enough: blank separator lines and trailing-space trimming make the
        # measured content width disagree with `@maxes`, leaving the right border
        # ragged. Assigned directly to avoid the `Resize`-before-store recursion
        # `width=` would trigger via our own `Resize` handler.
        @width = row_width + ihorizontal

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
        # Re-pin the size now that the CSS cascade has run. `#rows=` pins width
        # at construction/Attach time, but a border arriving via CSS isn't folded
        # into `style` yet then, so `ihorizontal` would omit the border columns and
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
          @width = row_width + ihorizontal
          @height = Math.max(0, 2 * @rows.size - 1) + ivertical
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
        # (cached, see `#cached_col_for_x`) only when CSS per-cell rules exist,
        # since a plain table re-renders every frame. `@styled_rows` lets unstyled
        # rows skip per-cell lookups entirely (~20x faster on an unstyled table).
        refresh_styled_rows
        col_map = if (cc = @css_cells) && !cc.empty?
                    cached_col_for_x
                  end

        # Apply header/cell attributes to text cells that still hold the default
        # attribute (so explicit tags inside cells are preserved).
        #
        # Walks are clamped to the screen: a table scrolled/positioned partly off
        # the top/left edge has negative `yi`/`xi`, and `Indexable#[]?` wraps
        # negative indices — recoloring cells at the far end of the buffer.
        y = Math.max(itop, -yi)
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
            row_map = col_map.try { |cm| styled_row?(row_index) ? cm : nil }
            x = Math.max(ileft, -xi)
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

        # Internal grid rows are addressed relative to the real content origin
        # (`ytop = yi + itop - 1`), not a hardcoded `itop == 1`: with vertical
        # padding (`itop > 1`) the whole doubled-row grid shifts down with the
        # text, so the `─` fills and `┼` junctions land on the blank separator
        # rows instead of overwriting the padded cell text. The outer `┬`/`┴`
        # rows stay pinned to the actual top/bottom border rows (which the
        # padding band separates from the content). Mirrors the x axis, which
        # already offsets by `ileft`.
        ytop = yi + itop - 1

        # Gridline glyphs at the effective tier, hoisted out of the per-cell
        # loops below (`#glyph` walks to the window; once per render is enough).
        tier = glyph_tier
        g_h = Glyphs[Glyphs::Role::LineHorizontal, tier]
        g_v = Glyphs[Glyphs::Role::LineVertical, tier]
        g_cross = Glyphs[Glyphs::Role::JunctionCross, tier]
        g_tee_l = Glyphs[Glyphs::Role::JunctionTeeLeft, tier]
        g_tee_r = Glyphs[Glyphs::Role::JunctionTeeRight, tier]
        g_tee_t = Glyphs[Glyphs::Role::JunctionTeeTop, tier]
        g_tee_b = Glyphs[Glyphs::Role::JunctionTeeBottom, tier]

        # Draw border junctions row by row (each table row spans two grid rows).
        ry = 0
        while ry <= rows_n * 2
          bottom = (ry // 2) == rows_n
          row =
            if ry == 0
              yi + border.top - 1
            elsif bottom
              coords.yl - border.bottom
            else
              ytop + ry
            end

          # Clip to the rendered coords: a scrollable / `overflow: Hidden`
          # ancestor lowers `coords.yl`, but the screen buffer still holds the
          # rows below it — stop before stamping gridlines outside the widget's
          # visible rectangle (`lines[...]?` alone only guards the buffer).
          break if row >= coords.yl

          # With no top border the `ry == 0` junction row computes to `yi - 1` —
          # one row ABOVE the widget (the bottom junction is naturally clipped by
          # the `coords.yl` check above) — skip it. A row scrolled above the
          # screen (negative) is skipped too: `lines[...]?` wraps negative
          # indices to the far end of the buffer.
          if (ry == 0 && border.top == 0) || row < 0
            ry += 2
            next
          end

          line = lines[row]?
          break unless line

          rx = 0
          @maxes.each_with_index do |max, mi|
            rx += max

            # First column draws the left edge on the box border, independent of
            # the last-column handling below, so a single-column table gets both.
            # Skipped when the column sits left of the screen (negative wrap).
            if mi == 0
              if xi >= 0 && (cell = line[xi]?)
                cell.attr = battr
                if ry != 0 && !bottom
                  cell.char = border.left > 0 ? g_tee_l : g_h
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
              #
              # Positions are `xi + ileft + rx` (content begins at the left inset
              # `ileft`, not a hardcoded one column); `rx` is the content-column
              # offset. Both cells are clipped past the visible right edge.
              internal = ry != 0 && !bottom
              if 0 <= (xi + ileft + rx) < coords.xl && (cell = line[xi + ileft + rx]?)
                rx += 1
                cell.attr = battr
                cell.char = g_h if internal
                line.dirty = true
              end
              if internal && 0 <= (xi + ileft + rx) < coords.xl && (cell = line[xi + ileft + rx]?)
                cell.attr = battr
                cell.char = border.right > 0 ? g_tee_r : g_h
                line.dirty = true
              end
              next
            end

            # Center junction between this column and the next (never reached for
            # the last column, which returned above). Painted at `xi + ileft + rx`
            # (see the last-column note); `rx += 1` steps past the separator.
            # Stop once the junction would fall outside the visible right edge;
            # columns left of the screen (negative) are skipped, not stamped
            # wrapped at the buffer's right end.
            break if (xi + ileft + rx) >= coords.xl
            if (xi + ileft + rx) >= 0 && (cell = line[xi + ileft + rx]?)
              if ry == 0
                cell.attr = battr
                cell.char = border.top > 0 ? g_tee_t : g_v
              elsif bottom
                cell.attr = battr
                cell.char = border.bottom > 0 ? g_tee_b : g_v
              else
                cell.attr = junction_attr(battr, ry <= 2 ? hattr : cattr)
                cell.char = g_cross
              end
              line.dirty = true
            end
            rx += 1
          end

          ry += 2
        end

        # Draw internal horizontal/vertical border runs (relative to `ytop`).
        ry = 1
        while ry < rows_n * 2
          row = ytop + ry
          break if row >= coords.yl
          # Rows scrolled above the screen are skipped, not wrapped (see the
          # junction pass).
          if row < 0
            ry += 1
            next
          end
          line = lines[row]?
          break unless line

          if ry.odd?
            draw_vertical_separators line, xi, battr, width: width
          else
            # Horizontal `─` fill across each column's content cells. Start at the
            # left content inset (`ileft`), not a hardcoded column 1. Columns left
            # of the screen (negative) are skipped, not wrapped.
            rx = ileft
            @maxes.each do |max|
              max.times do
                break unless line[xi + rx + 1]?
                break if (xi + rx) >= coords.xl
                if (xi + rx) >= 0 && (cell = line[xi + rx]?)
                  cell.attr = junction_attr(battr, cell.attr)
                  cell.char = g_h
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
