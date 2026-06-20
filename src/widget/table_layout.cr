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

      # Extra padding added to each column when the table is sized to its
      # content (i.e. when no fixed `width` is set).
      property pad : Int32 = 2

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
        @maxes = [] of Int32
        return if @rows.empty?

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

        total = maxes.sum + maxes.size + 1

        if (fixed = numeric_width) && fixed >= total
          missing = fixed - total
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

      private def numeric_width : Int32?
        (w = @width).is_a?(Int32) ? w : nil
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

        while clen < width
          if align.h_center?
            cell = " #{cell} "
            clen += 2
          elsif align.right?
            cell = " #{cell}"
            clen += 1
          else
            cell = "#{cell} "
            clen += 1
          end
        end

        while clen > width && !cell.empty?
          if align.h_center? || align.right?
            cell = cell[1..]
          else
            cell = cell[0...-1]
          end
          clen -= 1
        end

        cell
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
