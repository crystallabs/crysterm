require "./list"
require "../layout/table_layout"

module Crysterm
  class Widget
    # Interactive list rendered as a table.
    #
    # Combines `Widget::List` (selectable rows, keyboard/mouse navigation) with
    # the column layout of `Widget::Table`. The first row of the supplied data
    # is treated as a fixed header that stays pinned at the top while the body
    # rows scroll.
    #
    # ```
    # Widget::ListTable.new(
    #   parent: screen,
    #   keys: true,
    #   rows: [
    #     ["Name", "Score"],
    #     ["Alice", "10"],
    #     ["Bob", "7"],
    #   ]
    # )
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![ListTable screenshot](../../examples/widget/listtable/listtable-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class ListTable < List
      include TableLayout

      # The table data (including the header row at index 0).
      property rows : Array(Array(String)) = [] of Array(String)

      # Whether every other body row is painted with `style.alternate_row`, like
      # Qt's `QAbstractItemView#alternatingRowColors`. No visible effect until
      # `style.alternate_row` is given a distinct background.
      property? alternate_rows : Bool = false

      # Whether clicking a header cell sorts the body by that column (toggling
      # ascending/descending), like Qt's `QTableView#sortingEnabled`.
      property? sortable : Bool = false

      # Column the body is currently sorted by, and the direction, set by
      # `#sort_by_column` (and by clicking a header cell). `nil` means unsorted.
      getter sort_column : Int32? = nil
      getter? sort_descending : Bool = false

      # The pinned header row.
      getter! header : Box

      def initialize(
        rows = nil,
        data = nil,
        pad = nil,
        no_cell_borders = nil,
        fill_cell_borders = nil,
        alternate_rows = false,
        sortable = false,
        *,
        align : Tput::AlignFlag | Shorthands = Tput::AlignFlag::Center,
        keys = nil, # Absorbed: `List` always enables key handling.
        **box,
      )
        self.cell_align = align
        @alternate_rows = alternate_rows
        @sortable = sortable
        pad.try { |v| @pad = v }
        no_cell_borders.try { |v| @no_cell_borders = v }
        fill_cell_borders.try { |v| @fill_cell_borders = v }

        super **box

        # Header overlay, pinned to the top of the list and kept above the
        # items. Positioned at `left: 0` / `top: 0` like the item boxes:
        # children are laid out relative to the list's *content* area (already
        # inside the border), so an `ileft` offset here would shift the header
        # right of the items and clip its last column.
        @header = Box.new(
          parent: self,
          left: 0,
          top: 0,
          height: 1,
          style: style.header,
          parse_tags: @parse_tags,
        )

        on(Crysterm::Event::Scroll) do
          header.front!
          # The header overlays item 0 (the spacer). Children are already
          # inset inside the list's border, so the header's top must track
          # `child_base` directly — adding the border width again would push it
          # down onto the first *data* row and hide it.
          header.top = @child_base
        end

        # Click a header cell to sort by that column (toggling direction). Uses
        # `Event::Mouse` (not bare `Click`) because it carries coordinates.
        if sortable?
          header.on(Crysterm::Event::Mouse) do |e|
            next unless e.action.down?
            if col = column_at(e.x - header.aleft)
              desc = @sort_column == col ? !@sort_descending : false
              sort_by_column col, desc
              request_render
            end
          end
        end

        on(Crysterm::Event::Attach) { set_data @rows }
        on(Crysterm::Event::Resize) do
          sel = selected
          set_data @rows
          selekt sel
          request_render
        end

        set_data(rows || data)
      end

      # Body rows draw with `style.cell`; selected rows with `styles.selected`;
      # and — when `#alternate_rows?` — every other body row with
      # `style.alternate_row`.
      def render_style_for(item : Widget) : Style
        # A CSS rule may target this row individually (`ListTable Box`,
        # `Box:nth-child(even)`); use its computed style, reflecting selection
        # through the widget state so `:selected` rules apply.
        if item.css_styled?
          selected = item_selected?(item)
          item.state = selected ? WidgetState::Selected : WidgetState::Normal
          base = item.style
          return selection_overlay(base) if selected
          # Even (alternating) body rows pick up the table-level
          # `alternate-background-color`. It is held on the *normal* style's
          # `alternate_row` (a table-wide appearance, independent of the table's
          # own focus/selection state), so read it from there rather than the
          # current-state `style`, then overlay onto the row's own CSS style (the
          # per-item path would otherwise return that verbatim).
          # `alternate_row?` (a cheap nil check) gates before the O(items)
          # `@items.index` scan, so an unstyled table skips it for every row.
          n = styles.normal
          if alternate_rows? && n.alternate_row? && (i = @items.index item) && i > 0 && i.even?
            return overlay_colors(base, n.alternate_row)
          end
          return base
        end

        return item_render_style(true) if item_selected?(item)

        if alternate_rows? && (i = @items.index item) && i > 0 && i.even?
          base = style.alternate_row
          return base unless base.border.any?
          borderless = base.dup
          borderless.border = false
          return borderless
        end

        item_render_style false
      end

      # Sorts the body rows (the header at index 0 stays pinned) by *col*. Cells
      # that both parse as numbers compare numerically; otherwise they compare as
      # tag-stripped text. Re-applies the current sort whenever data is set.
      def sort_by_column(col : Int32, descending = false)
        @sort_column = col
        @sort_descending = descending
        return if @rows.size <= 2

        head = @rows.first
        body = @rows[1..].sort do |a, b|
          cmp = compare_cells(a[col]? || "", b[col]? || "")
          descending ? -cmp : cmp
        end

        rebuilt = [head]
        rebuilt.concat body
        set_data rebuilt
      end

      private def compare_cells(a : String, b : String) : Int32
        ca = clean_tags a
        cb = clean_tags b
        an = ca.to_f?
        bn = cb.to_f?
        if an && bn
          (an <=> bn) || 0
        else
          ca <=> cb
        end
      end

      # Maps a header-local x offset onto a column index using the cached column
      # widths (`@maxes`). Returns `nil` for a negative offset.
      private def column_at(x : Int32) : Int32?
        return nil if x < 0
        acc = 0
        @maxes.each_with_index do |m, i|
          acc += m + 1 # +1 for the inter-column separator
          return i if x < acc
        end
        @maxes.empty? ? nil : @maxes.size - 1
      end

      # Body rows draw with `style.cell` (selected rows with `styles.selected`),
      # mirroring Blessed's `style.item = style.cell` mapping — whereas a plain
      # `List` uses `style.item`. `Style#cell` falls back to the list's own
      # style when no `cell:` style is given, so the default look is unchanged.
      def item_render_style(selected : Bool) : Style
        base = selected ? styles.selected : style.cell
        return base unless base.border.any?

        borderless = base.dup
        borderless.border = false
        borderless
      end

      # :ditto:
      def set_rows(rows)
        set_data rows
      end

      # Replaces the table data and rebuilds items + header.
      def set_data(rows)
        sel = @ritems[selected]?

        @rows = normalize_rows rows
        invalidate_maxes
        calculate_maxes
        return if @maxes.empty?

        # Size the widget to the table's content width. A list otherwise sizes
        # to its full-width item children (it has no content of its own to
        # shrink to), which would stretch the last column across the whole
        # parent and clip the header. `@maxes.sum + separators + insets` is the
        # exact width of a rendered row plus the border/padding.
        #
        # The ivar is assigned directly rather than via `width=`: that setter
        # emits `Resize` *before* storing the new value, and our own `Resize`
        # handler calls `set_data` again — which would see the old width and
        # re-emit, recursing forever. A direct assignment just updates the size
        # for the upcoming render.
        @width = row_width + iwidth

        # Index 0 is a spacer that the pinned header overlays.
        items = [""]
        @rows.each_with_index do |row, i|
          text = render_row row
          if i == 0
            header.set_content text
          else
            items << text
          end
        end

        set_items items
        header.front!

        # Try to keep the previous selection.
        if sel && (i = @ritems.index(sel))
          selekt i
        else
          selekt Math.min(selected, @items.size - 1)
        end
      end

      # The header spacer (item 0) is never selectable.
      def selekt(index : Int)
        index = 1 if index == 0
        if index <= @child_base
          scroll_to Math.max(@child_base - 1, 0)
        end
        super index
      end

      def render(with_children = true)
        # Re-pin the width now that the CSS cascade has run (it runs at the top
        # of the screen's `_render`, before any widget renders). `set_data` pins
        # the width at construction/Attach time, but a border arriving via CSS
        # isn't folded into `style` yet then, so `iwidth` would omit the border
        # columns and leave the box too narrow — the header and separators would
        # then disagree with the box edge. Recomputing here converges them on the
        # first rendered frame. Assigned directly (not via `width=`) to avoid the
        # `Resize`-before-store recursion our own `Resize` handler would trigger.
        calculate_maxes
        @width = row_width + iwidth unless @maxes.empty?

        coords = super
        return coords unless coords

        return coords if @maxes.empty?

        draw_borders coords
        recolor_css_cells coords
        coords
      end

      # Overlays CSS per-cell styles (`Table Cell`, `Cell:nth-child(...)`) on top
      # of the per-row colors, recoloring only the cells a rule targeted. Each
      # row occupies one line (`item.top == index`); columns map from `@maxes`.
      private def recolor_css_cells(coords)
        cells = @css_cells
        return if cells.nil? || cells.empty?

        lines = screen.lines
        xi = coords.xi
        yi = coords.yi
        width = coords.xl - coords.xi - iright
        height = coords.yl - coords.yi - ibottom

        col_for_x = {} of Int32 => Int32
        cx = ileft
        @maxes.each_with_index do |max, col_i|
          (cx...cx + max).each { |xpos| col_for_x[xpos] = col_i }
          cx += max
        end

        y = itop
        while y < height
          row = y - itop
          if line = lines[yi + y]?
            x = ileft
            while x < width
              col = col_for_x[x]?
              cell_style = col ? css_cell_style(row, col) : nil
              if cell_style && (cell = line[xi + x]?)
                cell.attr = sattr cell_style
                line.dirty = true
              end
              x += 1
            end
          end
          y += 1
        end
      end

      # Draws the vertical cell separators (and their top/bottom junctions).
      # Ported from Blessed's `ListTable.prototype.render`.
      private def draw_borders(coords)
        border = style.border
        return if !border.any? || no_cell_borders?

        lines = screen.lines
        xi = coords.xi
        yi = coords.yi
        battr = sattr border
        height = coords.yl - coords.yi - ibottom
        last = @maxes.size - 1

        # Top/bottom junctions per grid row.
        ry = 0
        (height + 1).times do
          line = lines[yi + ry]?
          break unless line

          rx = 0
          (0...last).each do |mi|
            rx += @maxes[mi]
            next unless line[xi + rx + 1]?
            rx += 1
            if cell = line[xi + rx]?
              if ry == 0
                cell.attr = battr
                cell.char = border.top > 0 ? '┬' : '│'
                line.dirty = true
              elsif ry == height
                cell.attr = battr
                cell.char = border.bottom > 0 ? '┴' : '│'
                line.dirty = true
              end
            end
          end

          ry += 1
        end

        # Internal vertical separators.
        ry = 1
        while ry < height
          line = lines[yi + ry]?
          break unless line

          rx = 0
          (0...last).each do |mi|
            rx += @maxes[mi]
            next unless line[xi + rx + 1]?
            rx += 1
            if cell = line[xi + rx]?
              cell.attr = junction_attr(battr, cell.attr)
              cell.char = '│'
              line.dirty = true
            end
          end

          ry += 1
        end
      end
    end
  end
end
