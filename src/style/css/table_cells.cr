module Crysterm
  module CSS
    # Per-cell CSS support shared by `Table` and `ListTable`: each cell is
    # emitted as a `Cell` node inside a `Row` node (header cells also `Header`),
    # so selectors can target cells individually — `Table Cell`,
    # `Cell:nth-child(2)` (a column), `Header`, `Row:nth-child(even)`. The
    # cascade computes a `Style` per cell, retrievable via `#css_cell_style`.
    #
    # Including this overrides the `Widget` extra-node hooks. The widget must
    # provide `#rows`, `#style`, `#alternate_rows?` and `#uid`.
    module TableCells
      @css_cells : Hash(Tuple(Int32, Int32), Style)?

      # Reused, allocation-free scratch set: data-row indices carrying a
      # CSS-computed cell style this frame. Rebuilt per render via
      # `#refresh_styled_rows`; the default theme styles only row 0 (Header), so
      # an otherwise-unstyled table skips per-cell CSS lookups for every body row.
      @styled_rows = Set(Int32).new

      private def css_cells : Hash(Tuple(Int32, Int32), Style)
        @css_cells ||= {} of Tuple(Int32, Int32) => Style
      end

      # Rebuilds `@styled_rows` from `@css_cells`, reusing the same Set
      # (clear + repopulate) so a per-render refresh allocates nothing. A `nil`
      # or empty `@css_cells` leaves the set empty.
      def refresh_styled_rows : Nil
        @styled_rows.clear
        @css_cells.try &.each_key { |(r, _)| @styled_rows << r }
      end

      # Whether data row *r* carries a CSS-computed cell style (see
      # `#refresh_styled_rows`).
      def styled_row?(r : Int32) : Bool
        @styled_rows.includes?(r)
      end

      # CSS-computed style for the cell at *row*/*col*, or `nil` if no rule
      # targeted it (renderer then uses its header/cell/alternate default).
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
          # A whole-row slot first (`Row { ... }`), then each cell. The cascade
          # applies the row slot before the cells (see `Cascade`), so the row
          # style becomes each cell's base and `Cell` rules layer on top.
          slots << "row:#{ridx}"
          row.each_index { |cidx| slots << "cell:#{ridx}:#{cidx}" }
        end
        slots
      end

      # Default a slot's rules apply onto: header style for row 0, alternate
      # style for alternating body rows, otherwise the cell style. For a cell
      # slot whose row already received a `Row { ... }` style (fanned into
      # `@css_cells` by the earlier row-slot pass), that row style is the base
      # instead, so `Row` + `Cell` rules cascade together (cell wins).
      def css_extra_base_style(slot : String) : Style
        unless slot.starts_with?("row:")
          row, col = parse_css_cell(slot)
          if existing = @css_cells.try &.[{row, col}]?
            return existing
          end
        end
        row = css_slot_row(slot)
        if row == 0
          style.header
        elsif alternate_rows? && row.even?
          style.alternate_row
        else
          style.cell
        end
      end

      def css_set_extra_style(slot : String, computed : Style) : Nil
        if slot.starts_with?("row:")
          # Fan the computed row style out onto every cell of the row, giving
          # each its own copy (a `Cell` rule dups-and-overrides it afterwards).
          row = css_slot_row(slot)
          if r = rows[row]?
            r.each_index { |col| css_cells[{row, col}] = computed.dup }
          end
        else
          row, col = parse_css_cell(slot)
          css_cells[{row, col}] = computed
        end
      end

      def css_reset_extra : Nil
        @css_cells.try &.clear
      end

      private def parse_css_cell(slot : String) : Tuple(Int32, Int32)
        parts = slot.split(':') # "cell:<row>:<col>"
        {parts[1].to_i, parts[2].to_i}
      end

      # The row index encoded in a slot, from either `row:<row>` or
      # `cell:<row>:<col>` — the second `:`-delimited field in both.
      private def css_slot_row(slot : String) : Int32
        slot.split(':')[1].to_i
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
