module Crysterm
  module CSS
    # Per-cell CSS support shared by `Table` and `ListTable`: each cell is
    # emitted as a `Cell` node inside a `Row` node (header cells are also
    # `Header`), so selectors can target cells individually — `Table Cell`,
    # `Cell:nth-child(2)` (a column), `Header`, `Row:nth-child(even)`. The
    # cascade computes a `Style` per cell and stores it here; each widget's
    # renderer looks it up with `#css_cell_style`.
    #
    # Including this overrides the `Widget` extra-node hooks. The widget must
    # provide `#rows`, `#style`, `#alternate_rows?` and `#uid` (both table
    # widgets do).
    module TableCells
      @css_cells : Hash(Tuple(Int32, Int32), Style)?

      private def css_cells : Hash(Tuple(Int32, Int32), Style)
        @css_cells ||= {} of Tuple(Int32, Int32) => Style
      end

      # The CSS-computed style for the cell at *row*/*col*, or `nil` if no rule
      # targeted it (the renderer then uses its header/cell/alternate default).
      def css_cell_style(row : Int32, col : Int32) : Style?
        @css_cells.try &.[{row, col}]?
      end

      def css_render_extra(io : IO) : Nil
        rows.each_with_index do |row, ridx|
          io << "<w-row data-uid=\"" << uid << "::row:" << ridx << "\" class=\"Row\">"
          row.each_index do |cidx|
            io << "<w-cell data-uid=\"" << uid << "::cell:" << ridx << ':' << cidx << '"'
            io << " class=\"" << (ridx == 0 ? "Cell Header" : "Cell") << "\"></w-cell>"
          end
          io << "</w-row>"
        end
      end

      def css_extra_slots : Array(String)
        slots = [] of String
        rows.each_with_index do |row, ridx|
          row.each_index { |cidx| slots << "cell:#{ridx}:#{cidx}" }
        end
        slots
      end

      # The default a cell's rules apply onto: the header style for row 0, the
      # alternate style for alternating body rows, otherwise the cell style.
      def css_extra_base_style(slot : String) : Style
        row, _ = parse_css_cell(slot)
        if row == 0
          style.header
        elsif alternate_rows? && row.even?
          style.alternate
        else
          style.cell
        end
      end

      def css_set_extra_style(slot : String, computed : Style) : Nil
        row, col = parse_css_cell(slot)
        css_cells[{row, col}] = computed
      end

      def css_reset_extra : Nil
        @css_cells.try &.clear
      end

      private def parse_css_cell(slot : String) : Tuple(Int32, Int32)
        parts = slot.split(':') # "cell:<row>:<col>"
        {parts[1].to_i, parts[2].to_i}
      end
    end
  end

  class Widget
    class Table
      include CSS::TableCells
    end

    class ListTable
      include CSS::TableCells
    end
  end
end
