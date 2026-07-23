require "./abstract_item_view"
require "../mixin/item_view"
require "../widget_table_layout"

module Crysterm
  class Widget
    # Interactive list rendered as a table.
    #
    # Combines `Mixin::ItemView` (selectable rows, keyboard/mouse navigation)
    # with the column layout of `Widget::Table`. The first row of the supplied
    # data is a fixed header pinned at the top while body rows scroll. It has no
    # exact Qt analogue.
    #
    # ```
    # Widget::ListTable.new(
    #   parent: window,
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
    # ![ListTable screenshot](../../tests/widget/listtable/listtable.5s.apng)
    # <!-- /widget-examples:capture -->
    class ListTable < AbstractItemView
      include Mixin::ItemView
      include TableLayout

      # The table data (including the header row at index 0). Read-only; assign
      # through `#rows=`, which rebuilds items + header.
      getter rows : Array(Array(String)) = [] of Array(String)

      # Whether every other body row is painted with `style.alternate_row`, like
      # Qt's `QAbstractItemView#alternatingRowColors`. No visible effect until
      # `style.alternate_row` is given a distinct background.
      property? alternate_rows : Bool = false

      # Whether clicking a header cell sorts the body by that column (toggling
      # ascending/descending), like Qt's `QTableView#sortingEnabled`.
      property? sortable : Bool = false

      # Disabling sorting also forgets the active sort column, so a later data
      # change doesn't keep re-imposing (and re-enabling doesn't resurrect) a
      # stale sort.
      def sortable=(value : Bool)
        return value if value == @sortable
        @sortable = value
        unless value
          @sort_column = nil
          @sort_descending = false
        end
        request_render
        value
      end

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
      # true, `#render`/`#rows=` keep pinning `@width = row_width + ihorizontal`, so
      # the table grows to fit every column and never overflows horizontally. When
      # false (a fixed `width:` was given), the width is left alone and the table
      # scrolls horizontally by column. Captured once, after `super`.
      @content_sized = true

      # Show a horizontal `ScrollBar` automatically when a fixed-width table's
      # columns overflow its viewport (Qt's `AsNeeded`).
      @horizontal_scrollbar_policy = ScrollBarPolicy::AsNeeded

      # --- per-row derived-style caches ---------------------------------------
      # `#render_style_for` runs once per body row per frame, and would otherwise
      # derive a fresh `Style` per even row per frame. The CSS cascade *replaces*
      # a widget's whole `styles` tree on recompute rather than mutating it, so a
      # derived `Style` stays valid until its source object is replaced — hence
      # these key on source-object identity (`same?`).

      # Non-CSS even rows: the source is one shared object across every even row,
      # so a single border-stripped derived style serves them all. Guarded by the
      # source's `attr_fingerprint` too: on the explicit-sub-style path (no
      # `alternate-background-color`) `Style#alternate_row` returns the same base
      # object forever, so identity alone would keep a stale derived copy across
      # in-place mutations of that sub-style.
      @_alt_row_src : Style? = nil
      @_alt_row_derived : Style? = nil
      @_alt_row_fp : Style::AttrFingerprint? = nil

      # CSS-styled rows: each row box carries its own computed `Style`, so these
      # memoize per source-`Style` identity. The whole set is dropped when
      # `styles.normal`'s identity flips — the cascade recompute that replaces
      # this widget's styles also replaces every row box's, so their old keys go
      # stale together.
      @_row_style_gen : Style? = nil
      @_row_wb = Cache::Bounded(Style, Style).new(Cache::LISTTABLE_ROW_CAPACITY, by_identity: true)      # without_border(item.style)
      @_row_overlay = Cache::Bounded(Style, Style).new(Cache::LISTTABLE_ROW_CAPACITY, by_identity: true) # overlay_colors(base, alternate_row)
      @_row_overlay_src : Style? = nil                                                                   # alternate_row source guarding @_row_overlay

      # NOTE: there is deliberately no `data:` parameter — it would collide with
      # the inherited `Widget#data` (`Mixin::Data`'s `UserData?` slot), as in
      # `Widget::Table`. Pass `rows:`.
      def initialize(
        rows : Array(Array(String))? = nil,
        column_spacing : Int32? = nil,
        alternate_rows : Bool = false,
        sortable : Bool = false,
        *,
        cell_borders : Bool = true,
        fill_cell_borders : Bool = false,
        align : Tput::AlignFlag | Shorthands = Tput::AlignFlag::Center,
        **box,
      )
        self.cell_align = align
        @alternate_rows = alternate_rows
        @sortable = sortable
        init_cell_options column_spacing, cell_borders, fill_cell_borders

        super **box

        # Remember whether the caller fixed a width: if so, leave it alone and
        # let the table scroll horizontally; otherwise size to content (below).
        @content_sized = @width.nil?

        # Header overlay, pinned to the top of the list, kept above the items.
        # Positioned at `left: 0` / `top: 0` like the item boxes: children are
        # laid out relative to the list's content area (already inside the
        # border), so an `ileft` offset here would shift the header right of the
        # items and clip its last column. Its style must be border-stripped —
        # the table draws the frame and `│` separators itself, and an inherited
        # border would give the header box insets that clip the last column.
        #
        # TODO: when content-sized (no explicit `width:`) the header collapses to
        # its text width instead of stretching to the row width, so
        # `style.header`'s background stops short of the right border.
        @header = Box.new(
          parent: self,
          left: 0,
          top: 0,
          height: 1,
          style: without_border(style.header),
          parse_tags: @parse_tags,
        )

        on(Crysterm::Event::Scroll) do
          header.to_front
          # Header overlays item 0 (the spacer). Children are already inset
          # inside the list's border, so the header's top must track
          # `child_base` directly — adding the border width again would push
          # it onto the first data row and hide it.
          header.top = @child_base
        end

        # Click a header cell to sort by that column (toggling direction). Uses
        # `Event::Mouse`, not bare `Click`, because it carries coordinates.
        # Installed unconditionally and gated on the *current* `sortable?`, so
        # toggling `sortable=` at runtime takes effect in both directions.
        header.on(Crysterm::Event::Mouse) do |e|
          next unless sortable? && e.action.down?
          if col = column_at(e.x - header.aleft)
            order = @sort_column == col ? (@sort_descending ? SortOrder::Ascending : SortOrder::Descending) : SortOrder::Ascending
            sort_by_column col, order
            request_render
          end
        end

        on(Crysterm::Event::Attached) { self.rows = @rows }
        on(Crysterm::Event::Resize) do
          # `#rows=` rebuilds `@maxes`/width and every item — only needed when the
          # column layout depends on the widget's own width, i.e. a fixed- or
          # percent-width table. A content-sized table's columns are
          # content-driven and don't change with the parent, so skip the rebuild
          # an interactive resize drag would otherwise fire on every step.
          unless @content_sized
            sel = current_index
            self.rows = @rows
            self.current_index = sel
          end
          request_render
        end

        self.rows = rows
      end

      # Body rows draw with `style.cell`; selected rows with `styles.selected`;
      # and — when `#alternate_rows?` — every other body row with
      # `style.alternate_row`.
      def render_style_for(item : Widget) : Style
        # A CSS rule may target this row individually (`ListTable Box`,
        # `Box:nth-child(even)`); use its computed style, reflecting selection
        # through the widget state so `:selected` rules apply.
        if item.css_styled?
          sync_row_style_cache
          selected = item_selected?(item)
          item.state = selected ? WidgetState::Selected : WidgetState::Normal
          # A row never draws its own border: the table owns the outer frame and
          # `│` column separators, so a cell box painting a border would nest a
          # frame inside each cell. Every path — including this per-item CSS one —
          # must strip it.
          base = css_without_border(item.style)
          return selection_overlay(base) if selected
          # Alternating body rows pick up the table-level
          # `alternate-background-color`, held on the normal style's
          # `alternate_row` (table-wide, independent of focus/selection), so read
          # it from there and overlay onto the row's own CSS style.
          # `alternate_row?` gates before the index lookup, so an unstyled table
          # skips it for every row. `item_index_of` is an O(1) identity map, not
          # the O(n) `@item_boxes.index` scan, which here would be O(n²) per frame; it
          # returns nil for a non-item child (the pinned header, a scroll bar), so
          # those keep falling through.
          n = styles.normal
          if alternate_rows? && n.alternate_row? && (i = item_index_of item) && i > 0 && i.even?
            return css_alt_overlay(base, n.alternate_row)
          end
          return base
        end

        return item_render_style(true) if item_selected?(item)

        if alternate_rows? && (i = item_index_of item) && i > 0 && i.even?
          return alt_row_style
        end

        item_render_style false
      end

      # Border-stripped `style.alternate_row` for the non-CSS alternating-row
      # path, memoized by source identity and attribute fingerprint: every even
      # row shares the one `style.alternate_row` object.
      private def alt_row_style : Style
        src = style.alternate_row
        derived, @_alt_row_src, @_alt_row_derived, @_alt_row_fp =
          Style.memo_derive(src, @_alt_row_src, @_alt_row_derived, @_alt_row_fp) do |s|
            without_border s
          end
        derived
      end

      # Drops the CSS-row derived-style caches when the cascade has replaced this
      # widget's styles (detected via `styles.normal`'s object identity), and —
      # so a live `#alternate_background_color=` still takes effect — when the
      # alternate-row source object changes.
      private def sync_row_style_cache : Nil
        gen = styles.normal
        unless @_row_style_gen.same?(gen)
          @_row_style_gen = gen
          @_row_wb.clear
          @_row_overlay.clear
          @_row_overlay_src = nil
        end
        src = gen.alternate_row
        unless @_row_overlay_src.same?(src)
          @_row_overlay_src = src
          @_row_overlay.clear
        end
      end

      # `without_border(src)` for a CSS row style, memoized by *src* identity.
      private def css_without_border(src : Style) : Style
        @_row_wb.fetch(src) { without_border(src) }
      end

      # `overlay_colors(base, source)` for a CSS even row, memoized by *base*
      # identity. *source* is shared across even rows and guards the cache in
      # `#sync_row_style_cache`, so keying on *base* alone is sufficient.
      private def css_alt_overlay(base : Style, source : Style) : Style
        @_row_overlay.fetch(base) { overlay_colors(base, source) }
      end

      # Sorts the body rows (the header at index 0 stays pinned) by *column*.
      # Cells that both parse as numbers compare numerically; otherwise they
      # compare as tag-stripped text. Re-applies the current sort whenever data
      # is set.
      def sort_by_column(column : Int32, order : SortOrder = :ascending)
        @sort_column = column
        @sort_descending = order.descending?
        # `#rows=` re-applies the active sort over `@rows`.
        self.rows = @rows
      end

      # Reorders the body rows of `@rows` in place according to the current
      # `@sort_column`/`@sort_descending`, leaving the header (index 0) pinned.
      # Does NOT call `#rows=` — both `sort_by_column` and the tail of
      # `#rows=` call it, so calling `#rows=` here would recurse forever.
      # A no-op when no sort is active or the table has at most one body row.
      private def apply_sort : Nil
        col = @sort_column
        return unless col
        return if @rows.size <= 2

        descending = @sort_descending
        head = @rows.first
        # Schwartzian transform: precompute one sort key per body row and sort the
        # keyed pairs, rather than re-stripping tags for both operands inside the
        # O(n log n) comparator.
        keyed = @rows[1..].map do |r|
          c = clean_tags(r[col]? || "")
          {c.to_f?, c, r}
        end
        keyed.sort! do |a, b|
          cmp = compare_keys(a[0], a[1], b[0], b[1])
          descending ? -cmp : cmp
        end

        @rows = [head]
        keyed.each { |k| @rows << k[2] }
      end

      # Compares two precomputed cell keys. When both cells parse as numbers they
      # compare numerically; otherwise their tag-stripped text compares.
      private def compare_keys(an : Float64?, ca : String, bn : Float64?, cb : String) : Int32
        if an && bn
          (an <=> bn) || 0
        else
          ca <=> cb
        end
      end

      # Maps a header-local x offset onto a column index using the cached column
      # widths (`@maxes`). Returns `nil` for a negative offset.
      private def column_at(x : Int32) : Int32?
        return if x < 0
        # Header/rows render from `@first_col`, so a click at relative `x == 0`
        # lands on column `@first_col`, not column 0.
        acc = 0
        (@first_col...@maxes.size).each do |i|
          acc += @maxes[i] + 1 # +1 for the inter-column separator
          return i if x < acc
        end
        @maxes.empty? ? nil : @maxes.size - 1
      end

      # Body rows draw with `style.cell` (selected rows with `styles.selected`);
      # a plain `List` uses `style.item` instead. `Style#cell` falls back to the
      # list's own style when no `cell:` is given.
      def item_render_style(selected : Bool) : Style
        without_border(selected ? styles.selected : style.cell)
      end

      # --- column-level horizontal scrolling ---------------------------------
      # A fixed-width `ListTable` (one given an explicit `width:`) can be narrower
      # than its columns; it then scrolls horizontally by whole columns. The
      # `ScrollBar` machinery in `widget_scrolling.cr` binds to `@child_base_x`
      # (the display-column offset of the first visible column), so these only
      # supply the table-specific width, overflow test, and column snapping.

      # Total content width in columns — the horizontal analogue of the scroll
      # height. `0` (no overflow) before the columns are measured.
      def scroll_width : Int32
        @maxes.empty? ? 0 : row_width
      end

      # A content-sized table grows to fit its columns and so never overflows;
      # a fixed-width one overflows once its columns exceed the viewport.
      #
      # Compared against the full interior (`awidth - ihorizontal`) — the width the
      # columns are laid out to fill (`compute_column_widths`) — *not* `content_width`.
      # `content_width` also subtracts the *vertical* scroll bar's reserved
      # column (`content_margin_x`); when a fixed-width table scrolls vertically,
      # `row_width` fills the interior exactly, so comparing against the narrower
      # `content_width` reported a phantom 1-column horizontal overflow and drew a
      # spurious horizontal scroll bar across the bottom row.
      def overflows_x?
        return false if @content_sized
        scroll_width > awidth - ihorizontal
      end

      # Scrolls horizontally by *offset* columns' worth of display columns,
      # snapping the result to a whole-column boundary (so a cell is never split
      # mid-width) and re-rendering the visible rows from the new first column.
      def scroll_by_x(offset = 1)
        return unless @scrollable && window?
        return if @content_sized || @maxes.empty?
        visible = content_width
        return if visible <= 0

        offsets = column_start_offsets
        max_left = Math.max(0, scroll_width - visible)
        max_col = column_for_offset max_left, offsets
        # Ceil: `column_for_offset` floors to the last column starting at or
        # before `max_left`. When no column starts exactly there (the normal
        # case, viewport wider than the last column), the row tail past that
        # column would be permanently unreachable. Permit snapping one column
        # further so the last columns can be brought on screen (whole-column
        # snap with blank slack on the right, which `reslice_rows` renders fine).
        max_col += 1 if max_col + 1 < offsets.size && (offsets[max_col]? || 0) < max_left
        base = @child_base_x
        new_col = column_for_offset (base + offset).clamp(0, max_left), offsets
        # A nonzero request that snaps back to the current column (e.g. a
        # one-cell wheel tick smaller than a column) still advances one whole
        # column, so scrolling responds to fine input.
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
      # (from `@first_col`), updating content in place — no item recreation, so
      # selection/state survive. All rows are resliced since vertical scrolling
      # does not re-slice. Called when the horizontal offset changes.
      private def reslice_rows
        return if @maxes.empty?
        @rows.each_with_index do |row, i|
          text = render_row row, @first_col
          if i == 0
            header.set_content text
          elsif @item_boxes[i]?
            # Pass the index (not the widget): `set_item(widget, …)` re-resolves
            # it with `@item_boxes.index` (O(n)) inside this per-row loop — O(n²) per
            # scroll tick. The loop already has `i`.
            set_item i, content: text
          end
        end
      end

      # Replaces the table data and rebuilds items + header.
      #
      # A real setter, not the one `property rows` used to generate: that one
      # assigned `@rows` and stopped, bypassing `#reload_rows`, so the column
      # widths and rendered rows kept describing the OLD data (see
      # `Widget::Table#rows=`). `set_data`/`set_rows` — the two names the working
      # path used to carry — are folded in here.
      def rows=(rows)
        sel = @ritems[current_index]?
        prev_selected = current_index
        prev_count = @ritems.size

        # One-way width pin: for a content-sized table, clear the self-pinned
        # width before remeasuring so `compute_column_widths` sizes columns from
        # content again (the numeric-slack branch keys off a non-nil `@width`).
        # Without this the previously pinned width — including the scroll-bar
        # `reserve` folded in by `#render` — feeds back into the column widths and
        # the table grows one column per refresh and never shrinks. A fixed-width
        # table keeps its `@width` and its slack-distribution behaviour.
        @width = nil if @content_sized

        unless reload_rows rows
          # Empty/column-less data must empty the view too: `reload_rows` has
          # already replaced `@rows`, so returning with the old items/header
          # rendered would leave phantom rows — visible, clickable and
          # keyboard-selectable — against an empty model. (A still-empty view
          # is left alone, so constructing without rows stays item-less.)
          @first_col = 0
          @child_base_x = 0
          unless @item_boxes.empty?
            header.set_content ""
            self.items = [""] # index 0 is the header-spacer row
          end
          return
        end

        # Re-apply the active sort over the fresh body rows so the ordering is
        # preserved across every data change, not just an explicit
        # `sort_by_column` call. Reorders `@rows` in place (no `#rows=`, to
        # avoid recursion).
        apply_sort

        # Keep the horizontal offset valid across a data change (fewer columns),
        # and re-derive its display-column offset.
        @first_col = @first_col.clamp(0, Math.max(0, @maxes.size - 1))
        @child_base_x = column_start_offsets[@first_col]? || 0

        # Size the widget to the table's content width unless a fixed width was
        # given (then it scrolls horizontally instead). A list otherwise sizes
        # to its full-width item children, stretching the last column across
        # the whole parent and clipping the header. `@maxes.sum + separators +
        # insets` is the exact width of a rendered row plus border/padding.
        #
        # Assigned directly rather than via `width=`: that setter emits
        # `Resize` before storing the new value, and our `Resize` handler calls
        # `#rows=` again, which would see the old width and recurse forever.
        @width = row_width + ihorizontal if @content_sized

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

        self.items = items
        header.to_front

        # Try to keep the previous selection. When the row count is unchanged
        # (e.g. an in-place re-sort or reslice), restore by numeric index: a
        # value-based lookup can resolve an empty/duplicate cell to the wrong
        # row — including item 0, the header spacer `""`. Fall back to the
        # value-based lookup only when the row count changed.
        if @ritems.size == prev_count && prev_selected < @ritems.size
          self.current_index = prev_selected
        elsif sel && (i = @ritems.index(sel))
          self.current_index = i
        else
          self.current_index = Math.min(current_index, @item_boxes.size - 1)
        end
      end

      # The header spacer (item 0) is never selectable.
      def current_index=(index : Int)
        # Clamp to the first *data* row: index 0 is the header spacer
        # (`@ritems[0] == ""`, overlaid by the pinned header) and is not
        # selectable. Guarding only `== 0` let a negative index (e.g. PageUp /
        # Ctrl-B / Ctrl-U near the top, `selected - visible < 0`) slip through
        # and clamp to 0 in the parent, activating the empty header row.
        index = index.clamp(1, @item_boxes.size - 1) if @item_boxes.size > 1
        super index
        # After `super` scrolls the selection into view, a row near the top can
        # land at screen row 0 — the row the pinned header overlays — hiding it.
        # Nudge the viewport up one so the selected row shows *below* the header.
        # Running this *before* `super` missed big upward jumps (e.g. Home / PageUp
        # from a scrolled position), which `super` then re-scrolled to put the row
        # right back under the header, hiding the first data row.
        if index <= @child_base
          scroll_to Math.max(@child_base - 1, 0)
        end
      end

      def render(with_children = true)
        # Re-pin the width now that the CSS cascade has run (runs at the top of
        # the window's `repaint`, before any widget renders). `#rows=` pins
        # the width at construction/Attach time, but a border arriving via CSS
        # isn't folded into `style` yet then, so `ihorizontal` would omit the border
        # columns, leaving the box too narrow. Recomputing here converges header
        # and box edge on the first rendered frame. Assigned directly (not via
        # `width=`) to avoid the `Resize`-before-store recursion (see `#rows=`).
        #
        # Clear the self-pinned width first (content-sized only) so this remeasure
        # sizes columns from content rather than folding the previously pinned
        # width — including the scroll-bar `reserve` added below — back into the
        # columns. See `#rows=`.
        @width = nil if @content_sized
        compute_column_widths

        # Reserve the vertical scroll bar's column (when shown) for the pinned
        # header too, mirroring body items (synced in `Mixin::ItemView#render`).
        # The header is an interior overlay built by `render_row`, already
        # sliced for horizontal scroll like the rows, so it needs the same
        # right-edge reservation, else the shown bar overpaints its last
        # column. `right=` is a no-op when unchanged.
        reserve = content_margin_x
        header.right = reserve
        # A content-sized table widens by that column so the bar gets its own
        # cell instead of clipping the last data column; a fixed-width table
        # keeps its width and scrolls horizontally instead.
        @width = row_width + ihorizontal + reserve if @content_sized && !@maxes.empty?

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

        lines = window.lines
        xi, yi, width, height = border_extent coords

        # Map visible x → actual column index, starting from the first visible
        # column so per-cell CSS recolors correctly when scrolled right.
        # Cached (see `#cached_col_for_x`) since this runs every render.
        col_map = cached_col_for_x(@first_col)

        # Only rows carrying a computed cell style need per-cell lookups; an
        # unstyled table styles only its header row via the default theme, so
        # every body row is skipped wholesale.
        refresh_styled_rows

        y = itop
        while y < height
          # `@css_cells`/`@styled_rows` are keyed by *data-row* index (into
          # `#rows`, row 0 == header), but the body scrolls by `@child_base`, so
          # screen row `r >= 1` shows data row `r + @child_base`. Screen row 0 is
          # always the pinned header overlay (data row 0). Mapping the screen row
          # straight to the data row recolored the wrong rows once scrolled.
          screen_row = y - itop
          row = screen_row == 0 ? 0 : screen_row + @child_base
          if styled_row?(row) && (line = lines[yi + y]?)
            x = ileft
            while x < width
              col = col_map[x]?
              cell_style = col ? css_cell_style(row, col) : nil
              if cell_style && (cell = line[xi + x]?)
                cell.attr = style_to_attr cell_style
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
        return if !border.any? || !cell_borders?

        lines = window.lines
        xi, yi, width, height = border_extent coords
        battr = style_to_attr border
        last = @maxes.size - 1

        # Junction glyphs at the effective tier, hoisted out of the per-cell
        # loops (matches `Table#render`).
        tier = glyph_tier
        g_v = Glyphs[Glyphs::Role::LineVertical, tier]
        g_tee_t = Glyphs[Glyphs::Role::JunctionTeeTop, tier]
        g_tee_b = Glyphs[Glyphs::Role::JunctionTeeBottom, tier]

        # Separators are drawn between the visible columns (`@first_col..`),
        # with `rx` accumulating from the left of the viewport — matching the
        # rows, also re-rendered from `@first_col` — and clipped past the right edge.

        # Top/bottom junctions per grid row.
        ry = 0
        while ry <= height
          row = yi + ry
          # Junction rows only exist on an actual border row: with no top border
          # `ry == 0` is the header text row, and with no bottom border
          # `ry == height` is `yl - ibottom == yl` — one row BELOW the widget.
          # A negative row (widget partly above the screen) is skipped too:
          # `lines[...]?` wraps negative indices to the far end of the buffer.
          if row < 0 || (ry == 0 && border.top == 0) || (ry == height && border.bottom == 0)
            ry += 1
            next
          end
          line = lines[row]?
          break unless line

          # `rx` is the within-content column offset; the junction after column
          # `mi` is painted at `xi + ileft + rx` (content begins at the left
          # inset, not a hardcoded one column — matches
          # `TableLayout#draw_vertical_separators`). Clipped against the content
          # width (`width - ileft`, since `width` still includes the left inset)
          # and skipped for columns left of the screen (negative wrap).
          rx = 0
          (@first_col...last).each do |mi|
            rx += @maxes[mi]
            break if rx >= width - ileft
            if (ax = xi + ileft + rx) >= 0 && (cell = line[ax]?)
              if ry == 0
                cell.attr = battr
                cell.char = border.top > 0 ? g_tee_t : g_v
                line.dirty = true
              elsif ry == height
                cell.attr = battr
                cell.char = border.bottom > 0 ? g_tee_b : g_v
                line.dirty = true
              end
            end
            rx += 1
          end

          ry += 1
        end

        # Internal vertical separators. Rows scrolled above the screen are
        # skipped, not wrapped (see the junction pass).
        ry = 1
        while ry < height
          row = yi + ry
          if row < 0
            ry += 1
            next
          end
          line = lines[row]?
          break unless line

          draw_vertical_separators line, xi, battr, start_col: @first_col, width: width

          ry += 1
        end
      end
    end
  end
end
