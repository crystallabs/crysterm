require "./list"
require "../widget_table_layout"

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

      # Index of the first horizontally-visible column. `0` until the table is
      # given a fixed width narrower than its content and scrolled right. Scroll
      # is column-level: this snaps to whole columns and `@child_base_x` tracks
      # its display-column offset (so the horizontal `ScrollBar` binds to it).
      @first_col = 0

      # Whether the box is sized to its content width (no explicit `width:`). When
      # true, `#render`/`#set_data` keep pinning `@width = row_width + iwidth`, so
      # the table grows to fit every column and never overflows horizontally. When
      # false (a fixed `width:` was given), the width is left alone and the table
      # scrolls horizontally by column. Captured once, after `super`.
      @content_sized = true

      # Show a horizontal `ScrollBar` automatically when a fixed-width table's
      # columns overflow its viewport (Qt's `AsNeeded`).
      @horizontal_scrollbar_policy = ScrollBarPolicy::AsNeeded

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

        # Remember whether the caller fixed a width: if so, leave it alone and
        # let the table scroll horizontally; otherwise size to content (below).
        @content_sized = @width.nil?

        # Header overlay, pinned to the top of the list and kept above the
        # items. Positioned at `left: 0` / `top: 0` like the item boxes:
        # children are laid out relative to the list's *content* area (already
        # inside the border), so an `ileft` offset here would shift the header
        # right of the items and clip its last column.
        #
        # TODO (deferred to the width/scrollbar rework): when the table is
        # *content-sized* (no explicit `width:`) the header collapses to its text
        # width instead of stretching to the row width like the body items, so
        # its `style.header` background stops a few cells short of the right
        # border. The proper fix lives in the same content-width/scrollbar-width
        # model being reworked separately.
        # The header is an interior overlay: the table itself draws the frame and
        # the `│` column separators, so the header must not carry the table's
        # border. Inheriting it (via `style.header` folding in the table's
        # `border`) gave the header box `ileft`/`iright` insets that shrank its
        # content area by two columns, clipping the last visible column's text
        # (`City` → `Cit`). Strip it, mirroring the body rows' `render_style_for`.
        @header = Box.new(
          parent: self,
          left: 0,
          top: 0,
          height: 1,
          style: without_border(style.header),
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
          # A row never draws its own border: the table owns the outer frame and
          # the `│` column separators, so a cell box painting a border would nest
          # a frame inside each cell. The non-CSS paths strip it (`item_render_style`,
          # `without_border`); the per-item CSS style must too. (Before `Box` type
          # selectors matched, this branch was never reached for a plain cell.)
          base = without_border(item.style)
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
          return without_border(style.alternate_row)
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
        without_border(selected ? styles.selected : style.cell)
      end

      # :ditto:
      def set_rows(rows)
        set_data rows
      end

      # --- column-level horizontal scrolling ---------------------------------
      # A fixed-width `ListTable` (one given an explicit `width:`) can be narrower
      # than its columns; it then scrolls horizontally by whole columns. The
      # `ScrollBar` machinery in `widget_scrolling.cr` binds to `@child_base_x`
      # (the display-column offset of the first visible column), so these only
      # supply the table-specific width, overflow test, and column snapping.

      # Total content width in columns — the horizontal analogue of the scroll
      # height. `0` (no overflow) before the columns are measured.
      def get_scroll_width
        @maxes.empty? ? 0 : row_width
      end

      # A content-sized table grows to fit its columns and so never overflows;
      # a fixed-width one overflows once its columns exceed the viewport.
      def really_scrollable_x?
        return false if @content_sized
        get_scroll_width > content_width
      end

      # Scrolls horizontally by *offset* columns' worth of display columns,
      # snapping the result to a whole-column boundary (so a cell is never split
      # mid-width) and re-rendering the visible rows from the new first column.
      def scroll_x(offset = 1)
        return unless @scrollable && screen?
        return if @content_sized || @maxes.empty?
        visible = content_width
        return if visible <= 0

        offsets = column_start_offsets
        max_left = Math.max(0, get_scroll_width - visible)
        max_col = column_for_offset max_left, offsets
        base = @child_base_x
        new_col = column_for_offset (base + offset).clamp(0, max_left), offsets
        # A nonzero request that snaps back to the current column (e.g. a one-cell
        # wheel tick smaller than a column) still advances one whole column, so
        # column-level scrolling responds to fine input.
        if new_col == @first_col && offset != 0
          new_col = (@first_col + (offset <=> 0)).clamp(0, max_col)
        end
        snapped = offsets[new_col]? || 0
        return if snapped == base

        @first_col = new_col
        @child_base_x = snapped
        reslice_rows
        mark_dirty
        emit Crysterm::Event::Scroll, @child_base_x - base, Tput::Orientation::Horizontal
      end

      # Largest column index whose start offset is at or before *target*.
      private def column_for_offset(target : Int32, offsets : Array(Int32)) : Int32
        col = 0
        offsets.each_with_index do |o, i|
          break if o > target
          col = i
        end
        col
      end

      # Re-slices the header and every body item to the visible column window
      # (from `@first_col`), updating their content in place — no item recreation,
      # so selection/state survive. All rows are resliced (not just on-screen
      # ones) since vertical scrolling does not re-slice. Called when the
      # horizontal offset changes.
      private def reslice_rows
        return if @maxes.empty?
        @rows.each_with_index do |row, i|
          text = render_row row, @first_col
          if i == 0
            header.set_content text
          elsif item = @items[i]?
            set_item item, content: text
          end
        end
      end

      # Replaces the table data and rebuilds items + header.
      def set_data(rows)
        sel = @ritems[selected]?

        @rows = normalize_rows rows
        invalidate_maxes
        calculate_maxes
        return if @maxes.empty?

        # Keep the horizontal offset valid across a data change (fewer columns),
        # and re-derive its display-column offset.
        @first_col = @first_col.clamp(0, Math.max(0, @maxes.size - 1))
        @child_base_x = column_start_offsets[@first_col]? || 0

        # Size the widget to the table's content width *unless* a fixed width was
        # given (then it scrolls horizontally instead). A list otherwise sizes to
        # its full-width item children (it has no content of its own to shrink
        # to), which would stretch the last column across the whole parent and
        # clip the header. `@maxes.sum + separators + insets` is the exact width
        # of a rendered row plus the border/padding.
        #
        # The ivar is assigned directly rather than via `width=`: that setter
        # emits `Resize` *before* storing the new value, and our own `Resize`
        # handler calls `set_data` again — which would see the old width and
        # re-emit, recursing forever. A direct assignment just updates the size
        # for the upcoming render.
        @width = row_width + iwidth if @content_sized

        # Index 0 is a spacer that the pinned header overlays.
        items = [""]
        @rows.each_with_index do |row, i|
          text = render_row row, @first_col
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

        # Reserve the vertical scroll bar's column (when shown) for the pinned
        # header too, mirroring the body items (synced in `List#render`). The
        # header is an interior overlay built by `render_row` — already sliced for
        # horizontal scroll like the rows — so it just needs the same right-edge
        # reservation, else the shown bar overpaints its last column. `right=` is a
        # no-op when unchanged.
        reserve = content_margin_x
        header.right = reserve
        # A content-sized table widens by that column so the bar gets its own cell
        # instead of clipping the last data column; a fixed-width table keeps its
        # width and scrolls horizontally instead.
        @width = row_width + iwidth + reserve if @content_sized && !@maxes.empty?

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

        # Map visible x → actual column index, starting from the first visible
        # column so per-cell CSS recolors the right cells when scrolled right.
        col_map = col_for_x(@first_col, ileft)

        y = itop
        while y < height
          row = y - itop
          if line = lines[yi + y]?
            x = ileft
            while x < width
              col = col_map[x]?
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
        width = coords.xl - coords.xi - iright
        height = coords.yl - coords.yi - ibottom
        last = @maxes.size - 1

        # Separators are drawn between the *visible* columns (`@first_col..`), with
        # `rx` accumulating from the left of the viewport — matching the rows,
        # which are likewise re-rendered from `@first_col` — and clipped once they
        # pass the right edge.

        # Top/bottom junctions per grid row.
        ry = 0
        (height + 1).times do
          line = lines[yi + ry]?
          break unless line

          rx = 0
          (@first_col...last).each do |mi|
            rx += @maxes[mi]
            break if rx >= width
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
          (@first_col...last).each do |mi|
            rx += @maxes[mi]
            break if rx >= width
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
