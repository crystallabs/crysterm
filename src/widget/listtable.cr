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
    class ListTable < List
      include TableLayout

      # The table data (including the header row at index 0).
      property rows : Array(Array(String)) = [] of Array(String)

      # The pinned header row.
      getter! header : Box

      def initialize(
        rows = nil,
        data = nil,
        pad = nil,
        no_cell_borders = nil,
        fill_cell_borders = nil,
        *,
        align : Tput::AlignFlag | Shorthands = Tput::AlignFlag::Center,
        keys = nil, # Absorbed: `List` always enables key handling.
        **box,
      )
        self.cell_align = align
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

        on(Crysterm::Event::Attach) { set_data @rows }
        on(Crysterm::Event::Resize) do
          sel = selected
          set_data @rows
          selekt sel
          request_render
        end

        set_data(rows || data)
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
        coords = super
        return coords unless coords

        calculate_maxes
        return coords if @maxes.empty?

        draw_borders coords
        coords
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
