require "./abstract_item_view"
require "./table_layout"

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

      # The table data, as rows of string cells. Replace wholesale through
      # `#rows=`, or write one cell with `#[]=` — both rebuild the view.
      # Mutating the returned arrays directly bypasses that rebuild.
      getter rows : Array(Array(String))

      # Whether every other body row is painted with `style.alternate_row` instead
      # of `style.cell`. No visible effect until `style.alternate_row` gets a
      # distinct background.
      property? alternate_rows : Bool = false

      # A table is sized to its content by default.
      @shrink_to_fit = true

      # Content is pre-formatted into fixed-width columns; line-wrapping it would
      # push following rows down and desync the cell borders.
      @wrap_content = false

      # `style_to_attr` memos for the per-frame recolor/gridline pass, one per
      # style slot read there (`style`, `style.header`, `style.cell`,
      # `style.alternate_row`): a table redraws its borders every render with
      # unchanged styles, so each derivation is skipped until that slot's style
      # is mutated or swapped. The sub-style getters fall back to `self` /
      # a composed copy, but their identity is steady across frames (the
      # alternate-row composition is itself memoized), which is what makes the
      # {identity, revision} gate effective. Gridlines (`style.border`) stay
      # unmemoized: `Border` deliberately carries no `attr_revision`.
      @dattr_memo = Style::AttrMemo.new
      @hattr_memo = Style::AttrMemo.new
      @cattr_memo = Style::AttrMemo.new
      @aattr_memo = Style::AttrMemo.new

      # Whether the box is sized to its content width (no explicit `width:`).
      # When true, `#rows=`/`#paint` keep pinning `@width = row_width +
      # ihorizontal` so the box fits every column, but clear it before each
      # remeasure so the pin stays one-way (columns size from content and can
      # shrink again). When false (a fixed `width:` was given), the width is left
      # alone and `compute_column_widths` distributes its slack. Captured once,
      # after `super`.
      @content_sized = true

      # A `Table` is content-sized: `#paint` pins `@width` so the box always fits
      # every column and never overflows horizontally. It opts out of horizontal
      # scrolling entirely — a wide table is just clipped by its parent. For a
      # scrollable wide table use `Widget::ListTable` instead.

      # NOTE: there is deliberately no `data:` parameter — it would collide with
      # the inherited `Widget#data` (`Mixin::Data`'s `UserData?` slot). Pass
      # `rows:`.
      def initialize(
        rows : Array(Array(String))? = nil,
        column_spacing : Int32? = nil,
        alternate_rows : Bool = false,
        *,
        cell_borders : Bool = true,
        fill_cell_borders : Bool = false,
        align : Tput::AlignFlag | Shorthands = Tput::AlignFlag::Center,
        **box,
      )
        @rows = normalize_rows(rows)
        @alternate_rows = alternate_rows
        self.cell_align = align
        init_cell_options column_spacing, cell_borders, fill_cell_borders

        super **box

        # Remember whether the caller fixed a width. If so, leave it alone and
        # let `compute_column_widths` distribute its slack; otherwise size to
        # content. Captured before the first `self.rows =`, which pins `@width`.
        @content_sized = @width.nil?

        self.rows = @rows

        on(Crysterm::Event::Attached) { self.rows = @rows }
        on(Crysterm::Event::Resize) do
          self.rows = @rows
          update!
        end
      end

      # Replaces the table data and rebuilds the rendered content. Must go through
      # here rather than assigning `@rows`: that would bypass the rebuild,
      # leaving the column widths, the pinned `@width` and the content describing
      # the old data while `#paint` sized the box from the new row count.
      def rows=(rows)
        @rows = normalize_rows rows
        rebuild_from_rows
      end

      # ---- Cell model (Qt's `QTableWidget`) -----------------------------------

      # Number of rows held, **including** the header row at index 0 — the same
      # thing `#rows.size` reports, so the two can't disagree. (Qt's
      # `QTableWidget#rowCount` excludes the header because there the header is
      # a separate widget; a `Table`'s header is simply its first row, as in the
      # sibling `ListTable`.)
      def row_count : Int32
        @rows.size
      end

      # Number of columns — the widest row's cell count, which is also the
      # number of columns actually laid out.
      def column_count : Int32
        @rows.max_of?(&.size) || 0
      end

      # The cell at *row*/*col*, or `nil` when either index is out of range
      # (row 0 is the header row).
      def [](row : Int, col : Int) : String?
        @rows[row]?.try &.[col]?
      end

      # Replaces a single cell and repaints. Only the cell is written — the row
      # arrays are mutated in place and the content/column widths recomputed
      # from them, so one cell costs one cell rather than a whole-table copy
      # through `#rows=`. Out-of-range indices are a no-op, as is writing the
      # value already there.
      def []=(row : Int, col : Int, value : String) : String
        r = @rows[row]?
        return value unless r && 0 <= col < r.size
        return value if r[col] == value
        r[col] = value
        rebuild_from_rows
        update!
        value
      end

      # The header row's labels — row 0 of `#rows`, the row `style.header`
      # paints (mirroring `ListTable`, whose header is likewise row 0 of its
      # model). Empty when the table has no rows at all.
      def header_labels : Array(String)
        @rows[0]? || [] of String
      end

      # Replaces the header row, keeping every body row. On an empty table this
      # *adds* the header row. Rebuilds column widths and content.
      def header_labels=(labels : Array(String)) : Array(String)
        row = labels.map(&.to_s)
        if @rows.empty?
          @rows << row
        else
          @rows[0] = row
        end
        rebuild_from_rows
        update!
        labels
      end

      # Recomputes the column widths, the pinned width and the rendered content
      # from the current `@rows`, *without* re-normalizing (i.e. re-allocating)
      # them. Shared by `#rows=` and the in-place cell writers.
      protected def rebuild_from_rows : Nil
        # One-way width pin: for a content-sized table, clear the self-pinned
        # width before remeasuring so `compute_column_widths` sizes columns from
        # content again (its slack branch keys off a non-nil `@width`). Without
        # this the previously pinned width feeds back into the column widths and
        # the table can never shrink when its data gets narrower. A fixed-width
        # table keeps its `@width` and its slack-distribution behaviour.
        @width = nil if @content_sized

        invalidate_column_widths
        compute_column_widths

        if @maxes.empty?
          # Empty/column-less data must empty the view too: `@rows` has already
          # been replaced, so keeping the old content would show rows the model
          # no longer holds.
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
            str << render_row(row, 0, ri)
            str << "\n\n" unless is_footer
          end
        end

        set_content text
      end

      def paint(*, with_children = true)
        # Re-pin the size now that the CSS cascade has run: `#rows=` pins width at
        # construction/Attach time, before a border arriving via CSS is folded into
        # `style`, so `ihorizontal` would omit the border columns and leave
        # internal separators overshooting the right edge.
        #
        # Height is pinned too: cell-border junctions are placed relative to the
        # content rows, so a taller box would leave a half-drawn separator below
        # the last junction. Content spans `2*rows - 1` grid rows plus insets.
        #
        # Both assigned directly to avoid the `Resize`-before-store recursion our
        # own `Resize` handler would trigger.
        #
        # Clear the self-pinned width first (content-sized only) so this remeasure
        # sizes columns from content rather than folding the previously pinned
        # width back into the columns. See `#rows=`.
        @width = nil if @content_sized
        compute_column_widths
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

      # Recolors header/cell text and draws the internal cell borders.
      private def draw_borders(coords)
        recolor_cells coords

        return if !style.border.any? || !cell_borders?

        draw_junction_rows coords
        draw_grid_runs coords
      end

      # The gridline attribute: `gridline-color`, when set, overrides just the
      # gridlines' foreground while keeping the border's background/text
      # attributes.
      private def gridline_attr : Int64
        if gc = style.gridline_color
          style_to_attr style.border, fg: gc, bg: style.border.bg
        else
          style_to_attr style.border
        end
      end

      # Applies header/cell attributes to the rendered text cells.
      private def recolor_cells(coords)
        lines = window.cell_rows
        xi, yi, width, height = border_extent coords

        dattr = @dattr_memo.fetch(style)
        hattr = @hattr_memo.fetch(style.header)
        cattr = @cattr_memo.fetch(style.cell)
        aattr = @aattr_memo.fetch(style.alternate_row)

        # Maps each relative text-column x to its table column index, so CSS
        # per-cell styles can override the row default. Built only when per-cell
        # rules exist, since a plain table re-renders every frame; `@styled_rows`
        # lets unstyled rows skip the lookups entirely (~20x faster).
        refresh_styled_rows
        col_map = if (cc = @css_cells) && !cc.empty?
                    cached_col_for_x
                  end

        # Apply header/cell attributes to text cells that still hold the default
        # attribute, so explicit tags inside cells are preserved.
        #
        # Walks are clamped to the screen: a table positioned partly off the
        # top/left edge has negative `yi`/`xi`, and `Indexable#[]?` wraps negative
        # indices, recoloring cells at the far end of the buffer.
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
                  cell.attr = cell_style ? style_to_attr(cell_style) : default_attr
                  cell.mark_dirty
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
      end

      # Buffer row of the first internal grid row. The internal grid is addressed
      # relative to the real content origin, never a hardcoded `itop == 1`: with
      # vertical padding the whole doubled-row grid shifts down with the text, so
      # the `─` fills and `┼` junctions must follow it rather than overwrite the
      # padded cell text. The outer `┬`/`┴` rows stay pinned to the actual
      # top/bottom border rows.
      private def grid_top(coords) : Int32
        coords.yi + itop - 1
      end

      # Draws the border junctions row by row: the outer `┬`/`┴` rows on the box
      # border and the internal `├─┼─┤` rows between table rows (each table row
      # spans two grid rows).
      private def draw_junction_rows(coords)
        lines = window.cell_rows
        xi, yi, _width, _height = border_extent coords
        border = style.border
        battr = gridline_attr
        hattr = @hattr_memo.fetch(style.header)
        cattr = @cattr_memo.fetch(style.cell)
        g_cross = glyph Glyphs::Role::JunctionCross
        ytop = grid_top coords
        rows_n = @rows.size

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

          # Clip to the rendered coords: a scrollable / `overflow: Hidden` ancestor
          # lowers `coords.yl` while the screen buffer still holds the rows below
          # it, and `lines[...]?` alone only guards the buffer.
          break if row >= coords.yl

          # With no top border the `ry == 0` junction row computes to `yi - 1`, one
          # row above the widget. A row scrolled above the screen is skipped too:
          # `lines[...]?` wraps negative indices to the far end of the buffer.
          if (ry == 0 && border.top == 0) || row < 0
            ry += 2
            next
          end

          line = lines[row]?
          break unless line

          internal = ry != 0 && !bottom

          draw_junction_row_ends line, xi, battr, internal: internal, right_limit: coords.xl

          # Center junctions between adjacent columns — the shared boundary
          # walk (`TableLayout`), clipped at the visible right edge; columns
          # left of the screen are skipped, not stamped wrapped at the
          # buffer's right end.
          if internal
            each_junction_cell(line, xi, right_limit: coords.xl) do |jcell|
              jcell.attr = junction_attr(battr, ry <= 2 ? hattr : cattr)
              jcell.char = g_cross
              jcell.mark_dirty
            end
          else
            draw_edge_junctions line, xi, battr, top: ry == 0, right_limit: coords.xl
          end

          ry += 2
        end
      end

      # Stamps the two ends of one junction *line*: the box's left border, and
      # the trailing spare column the last cell is followed by plus the right
      # border one column further. On an internal row the rule continues across
      # the spare column with `├`/`┤` on the borders themselves; a naive
      # `xi + rx_last - 1` would leave a stray char short of the right one.
      # Content begins at the left inset `ileft`, not a hardcoded one column.
      private def draw_junction_row_ends(line, xi : Int32, battr : Int64, internal : Bool, right_limit : Int32) : Nil
        border = style.border
        tier = glyph_tier
        g_h = Glyphs[Glyphs::Role::LineHorizontal, tier]

        # The left end is handled independently of the right one, so a
        # single-column table gets both.
        if xi >= 0 && (cell = line[xi]?)
          cell.attr = battr
          if internal
            cell.char = border.left > 0 ? Glyphs[Glyphs::Role::JunctionTeeLeft, tier] : g_h
          end
          cell.mark_dirty
        end

        # Within-content offset of the trailing spare column after the last cell
        # (`sum(@maxes) + last` — the column contents plus the one-column
        # separators between them; see `#row_width`).
        edge = xi + ileft + row_width - 1
        if 0 <= edge < right_limit && (cell = line[edge]?)
          cell.attr = battr
          cell.char = g_h if internal
          cell.mark_dirty
          if internal && 0 <= edge + 1 < right_limit && (border_cell = line[edge + 1]?)
            border_cell.attr = battr
            border_cell.char = border.right > 0 ? Glyphs[Glyphs::Role::JunctionTeeRight, tier] : g_h
            border_cell.mark_dirty
          end
        end
      end

      # Draws the internal horizontal/vertical border runs, relative to the
      # content-origin grid top: each table row spans a text row (carrying the
      # `│` separators) and a separator row (carrying the `─` fills).
      private def draw_grid_runs(coords)
        lines = window.cell_rows
        xi, _yi, width, _height = border_extent coords
        battr = gridline_attr

        each_interior_grid_line(lines, grid_top(coords), @rows.size * 2, coords.yl) do |line, ry|
          if ry.odd?
            draw_vertical_separators line, xi, battr, width: width
          else
            draw_horizontal_rule line, xi, battr, right_limit: coords.xl
          end
        end
      end

      # Horizontal `─` fill across each column's content cells on one grid
      # *line*, starting at the left content inset `ileft`, not a hardcoded
      # column 1.
      private def draw_horizontal_rule(line, xi : Int32, battr : Int64, right_limit : Int32) : Nil
        g_h = glyph Glyphs::Role::LineHorizontal
        rx = ileft
        @maxes.each do |max|
          max.times do
            break unless line[xi + rx + 1]?
            break if (xi + rx) >= right_limit
            if (xi + rx) >= 0 && (cell = line[xi + rx]?)
              cell.attr = junction_attr(battr, cell.attr)
              cell.char = g_h
              cell.mark_dirty
            end
            rx += 1
          end
          rx += 1
        end
      end
    end
  end
end
