module Crysterm
  class Widget
    # Shared column-sizing and cell-padding logic for the table widgets
    # (`Widget::Table` and `Widget::ListTable`).
    #
    # The including widget must provide an `@rows` instance variable
    # (`Array(Array(String))`); everything else used here (`@maxes`, `pad`,
    # `cell_align`, the cell-border flags) is defined by the module itself, and
    # `@width`/`#str_width`/`#clean_tags` are inherited from `Widget`.
    module TableLayout
      # Computed per-column widths, filled in by `#calculate_maxes`.
      @maxes = [] of Int32

      # Whether `@maxes` needs recomputing. `#calculate_maxes` is called on every
      # `render` but only depends on `@rows`, `@width` and `@pad`; those change
      # exclusively through `#set_data` (invoked on data change, attach and
      # resize) and `#pad=`, both of which set this. Caching skips the per-frame
      # re-scan of every cell (each `clean_tags`/`str_width`) when nothing
      # relevant changed.
      @maxes_dirty : Bool = true

      # Extra padding added to each column when the table is sized to its
      # content (i.e. when no fixed `width` is set).
      getter pad : Int32 = 2

      # Setting `pad` invalidates the cached column widths.
      def pad=(value : Int32)
        @pad = value
        @maxes_dirty = true
      end

      # Marks the cached column widths (`@maxes`) stale so the next
      # `#calculate_maxes` recomputes them. Called by the table widgets from
      # `#set_data`.
      def invalidate_maxes
        @maxes_dirty = true
      end

      # When true, no internal cell borders are drawn (only the outer border,
      # if any).
      property? no_cell_borders : Bool = false

      # When true, internal cell-border junctions take the background color of
      # the cell they sit in, rather than the border background.
      property? fill_cell_borders : Bool = false

      # Horizontal alignment of cell text *within its column*. Kept separate
      # from the widget's own `@align`: for `Table`, the box align must stay at
      # the default (top-left) so it doesn't pad every line out to the full box
      # width and defeat shrink-to-content sizing; for `ListTable`, it keeps the
      # cell alignment independent of the list-item alignment. The cells are
      # already aligned here in `#pad_cell`.
      Crystallabs::Helpers::Enums.enum_property cell_align : Tput::AlignFlag = Tput::AlignFlag::Center

      # Computes per-column widths from the current `@rows`. When a fixed numeric
      # `width` is set and large enough, the slack is distributed evenly across
      # columns; otherwise each column is sized to its widest cell plus `@pad`.
      def calculate_maxes
        return @maxes unless @maxes_dirty
        @maxes_dirty = false

        @maxes = [] of Int32
        return @maxes if @rows.empty?

        maxes = [] of Int32
        @rows.each do |row|
          row.each_with_index do |cell, i|
            while maxes.size <= i
              maxes << 0
            end
            clen = cell_width cell
            maxes[i] = clen if maxes[i] < clen
          end
        end
        return if maxes.empty?

        # Minimum width of a rendered row: column contents, one separator
        # between each pair, plus the trailing spare column. This must match
        # `#row_width` exactly (`maxes.sum + maxes.size`).
        min_row = maxes.sum + maxes.size

        # Columns fill the box *interior* (inside the border/padding), so any
        # slack is distributed against `@width - iwidth`, not the full outer
        # `@width`. Targeting the full width left `row_width` one short of the
        # interior, so `Table#set_data`'s `@width = row_width + iwidth` grew the
        # table by `iwidth - 1` columns on every call — a feedback loop that made
        # a fixed-width table creep wider than requested.
        if (inner = numeric_inner_width) && inner >= min_row
          missing = inner - min_row
          per = missing // maxes.size
          rem = missing % maxes.size
          maxes = maxes.map_with_index do |max, i|
            i == maxes.size - 1 ? max + per + rem : max + per
          end
        else
          maxes = maxes.map { |max| max + @pad }
        end

        @maxes = maxes
      end

      # The interior content width when a fixed numeric `width` is set, i.e. the
      # box width minus the border/padding insets the columns render inside of.
      private def numeric_inner_width : Int32?
        (w = @width).is_a?(Int32) ? w - iwidth : nil
      end

      # Visible display width of a cell in terminal columns, with `{...}` tags
      # and SGR sequences stripped — they occupy no columns once the content is
      # parsed and rendered. Measuring the raw string (as `str_width` does)
      # would over-count tagged cells by the length of their tags, throwing off
      # column widths and the border separators that are positioned from them.
      def cell_width(cell : String) : Int32
        str_width clean_tags(cell)
      end

      # Renders one row of cells into a string, padding each cell to its column
      # width and separating columns with a single space.
      #
      # A trailing space is appended so the row is one column wider than its
      # visible content: Crysterm's content draw loop (`while x < xl - 1` in
      # `Widget#_render`) never paints the final content column, so without this
      # spare column a last cell filled to its full width would lose its last
      # character. `#row_width` accounts for this extra column.
      def render_row(row : Array(String)) : String
        String.build do |str|
          row.each_with_index do |cell, ci|
            str << ' ' if ci != 0
            str << pad_cell(cell, @maxes[ci]? || cell_width(cell))
          end
          str << ' '
        end
      end

      # The display width of a rendered row (see `#render_row`), including the
      # inter-column separators and the trailing spare column.
      def row_width : Int32
        @maxes.sum + (@maxes.size - 1) + 1
      end

      # Pads/clips a single cell's text to `width` columns according to the
      # widget's horizontal alignment.
      def pad_cell(cell : String, width : Int32) : String
        clen = cell_width cell
        align = cell_align

        if clen < width
          # Distribute the padding per alignment. For centered text an odd
          # remainder goes to the right side, matching the original loop (which
          # added a leading + trailing space per round, overshot by one on odd
          # widths, then trimmed one leading space back off).
          pad = width - clen
          left, right =
            if align.h_center?
              l = pad // 2
              {l, pad - l}
            elsif align.right?
              {pad, 0}
            else
              {0, pad}
            end

          String.build do |s|
            left.times { s << ' ' }
            s << cell
            right.times { s << ' ' }
          end
        elsif clen > width
          # Trim whole characters until the column count fits (or the cell
          # empties first), from the front for centered/right-aligned text and
          # from the end otherwise. `clen` counts display columns while the trim
          # removes characters one-for-one, so the count is capped at the
          # character length — exactly as the original per-character loop did.
          remove = Math.min(clen - width, cell.size)
          if align.h_center? || align.right?
            cell[remove..]
          else
            cell[0, cell.size - remove]
          end
        else
          cell
        end
      end

      # Normalizes arbitrary row data into rows of string cells.
      def normalize_rows(rows) : Array(Array(String))
        return [] of Array(String) unless rows
        rows.map { |row| row.map(&.to_s) }
      end

      # The attribute for an internal cell-border junction: either the plain
      # border attribute, or (with `fill_cell_borders`) the border
      # flags/foreground laid over the existing cell's background.
      def junction_attr(battr : Int64, over : Int64) : Int64
        return battr unless fill_cell_borders?
        Attr.pack Attr.flags(battr), Attr.fg(battr), Attr.bg(over)
      end
    end
  end
end
