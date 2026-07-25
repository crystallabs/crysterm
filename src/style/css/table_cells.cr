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

      # Data-row indices carrying a CSS-computed cell style this frame, so an
      # otherwise-unstyled table skips per-cell CSS lookups for every body row.
      @styled_rows = Set(Int32).new

      private def css_cells : Hash(Tuple(Int32, Int32), Style)
        @css_cells ||= {} of Tuple(Int32, Int32) => Style
      end

      # Rebuilds `@styled_rows` from `@css_cells`, reusing the same Set so a
      # per-render refresh allocates nothing.
      def refresh_styled_rows : Nil
        @styled_rows.clear
        @css_cells.try &.each_key { |(r, _)| @styled_rows << r }
      end

      # Whether data row *r* carries a CSS-computed cell style.
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
          # A whole-row slot first (`Row { ... }`), then each cell: the cascade
          # applies slots in order, so the row style becomes each cell's base
          # and `Cell` rules layer on top.
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
        # Parsed once: the `row:`/`cell:` gate picks the form, and the row index
        # the fall-back below needs comes out of the same parse. (The gate must
        # stay ahead of `parse_css_cell`, which has no `col` field to read on a
        # `row:<row>` slot.)
        if slot.starts_with?("row:")
          row = css_slot_row(slot)
        else
          row, col = parse_css_cell(slot)
          if existing = @css_cells.try &.[{row, col}]?
            return existing
          end
        end
        if row == 0
          style.header
        elsif alternate_rows? && row.even?
          style.alternate_row
        else
          style.cell
        end
      end

      protected def css_set_extra_style(slot : String, computed : Style) : Nil
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

      # The `{row, col}` of a `cell:<row>:<col>` slot. Raises on a `row:<row>`
      # slot, which carries no column — callers gate on `starts_with?("row:")`.
      private def parse_css_cell(slot : String) : Tuple(Int32, Int32)
        row, col = css_slot_indices(slot)
        raise ArgumentError.new("Not a table cell CSS slot: #{slot}") unless col
        {row, col}
      end

      # The row index encoded in a slot, from either `row:<row>` or
      # `cell:<row>:<col>` — the second `:`-delimited field in both.
      private def css_slot_row(slot : String) : Int32
        css_slot_indices(slot)[0]
      end

      # The indices encoded in an extra slot: `{row, nil}` for `row:<row>`,
      # `{row, col}` for `cell:<row>:<col>`.
      #
      # Scanned in place rather than via `split(':')`, so neither the parts
      # array nor the substrings are allocated — the cascade visits every extra
      # slot of every rule-matched table on every hover/drag event.
      private def css_slot_indices(slot : String) : Tuple(Int32, Int32?)
        first = slot.byte_index(':')
        raise ArgumentError.new("Malformed table CSS slot: #{slot}") unless first
        second = slot.byte_index(':', first + 1)
        row = css_slot_int(slot, first + 1, second || slot.bytesize)
        {row, second ? css_slot_int(slot, second + 1, slot.bytesize) : nil}
      end

      # Decimal digits of *slot* in byte range `[from, to)` as an `Int32`. The
      # indices are widget-generated, so only ASCII digits can appear.
      private def css_slot_int(slot : String, from : Int32, to : Int32) : Int32
        raise ArgumentError.new("Malformed table CSS slot: #{slot}") if from >= to
        value = 0
        (from...to).each do |i|
          digit = slot.byte_at(i) &- 48_u8
          raise ArgumentError.new("Malformed table CSS slot: #{slot}") if digit > 9
          value = value * 10 + digit
        end
        value
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
