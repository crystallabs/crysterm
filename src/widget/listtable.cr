require "./abstract_item_view"
require "../mixin/item_view"
require "../widget_table_layout"

module Crysterm
  class Widget
    # Interactive list rendered as a table.
    #
    # Combines `Mixin::ItemView` (selectable rows, keyboard/mouse navigation)
    # with the column layout of `Widget::Table`. The first row of the supplied
    # data is a fixed header pinned at the top while body rows scroll. A
    # sibling of `List` under `AbstractItemView` (no exact Qt class), reusing
    # row machinery via the mixin rather than inheritance.
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

      # Reused, allocation-free scratch set: rows that carry a CSS-computed cell
      # style this frame (`#recolor_css_cells` repopulates it from `@css_cells`).
      # The default theme styles only the `Header` (row 0), so an unstyled table
      # skips per-cell CSS lookups for every body row.
      @styled_rows = Set(Int32).new

      # --- per-row derived-style caches (allocation reduction, K1) -----------
      # `#render_style_for` runs once per body row per frame. With
      # `alternate_rows: true` that would derive a fresh `Style` for every even
      # row every frame (`without_border`/`overlay_colors` each `#dup`). The CSS
      # cascade replaces a widget's whole `styles` tree on recompute
      # (`cascade.cr`: `widget.styles = css_base_styles.deep_dup`) rather than
      # mutating it, so a derived `Style` stays valid until its source `Style`
      # object is replaced. These caches key on source-object identity
      # (`same?`) and rebuild only when the source changes.

      # Non-CSS even rows (`without_border(style.alternate_row)`): the source is
      # one shared object across every even row, so a single derived style
      # (border stripped once) serves them all until the source is replaced.
      @_alt_row_src : Style? = nil
      @_alt_row_derived : Style? = nil

      # CSS-styled rows: each row box carries its own computed `Style`, so these
      # memoize per source-`Style` identity in an identity-keyed `Hash`
      # (`Style` defines no `==`/`hash`, so keys compare by reference). The whole
      # set is dropped when `styles.normal`'s identity flips — the cascade
      # recompute that replaces this widget's styles also replaces every row
      # box's, so their old keys are stale together.
      @_row_style_gen : Style? = nil
      @_row_wb = {} of Style => Style      # without_border(item.style)
      @_row_overlay = {} of Style => Style # overlay_colors(base, alternate_row)
      @_row_overlay_src : Style? = nil     # alternate_row source guarding @_row_overlay

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
        keys = nil, # Absorbed: an item view always enables key handling.
        **box,
      )
        self.cell_align = align
        @alternate_rows = alternate_rows
        @sortable = sortable
        init_cell_options pad, no_cell_borders, fill_cell_borders

        super **box

        # Remember whether the caller fixed a width: if so, leave it alone and
        # let the table scroll horizontally; otherwise size to content (below).
        @content_sized = @width.nil?

        # Header overlay, pinned to the top of the list, kept above the items.
        # Positioned at `left: 0` / `top: 0` like the item boxes: children are
        # laid out relative to the list's content area (already inside the
        # border), so an `ileft` offset here would shift the header right of
        # the items and clip its last column.
        #
        # TODO (deferred to the width/scrollbar rework): when content-sized (no
        # explicit `width:`) the header collapses to its text width instead of
        # stretching to the row width, so `style.header`'s background stops a
        # few cells short of the right border.
        # The header must not carry the table's own border (the table draws the
        # frame and `│` separators itself). Inheriting it via `style.header`
        # gave the header box `ileft`/`iright` insets that shrank its content
        # area by two columns, clipping the last visible column's text
        # (`City` → `Cit`). Strip it, mirroring body rows' `render_style_for`.
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
          # Header overlays item 0 (the spacer). Children are already inset
          # inside the list's border, so the header's top must track
          # `child_base` directly — adding the border width again would push
          # it onto the first data row and hide it.
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
          # `set_data` rebuilds `@maxes`/width and every item — only needed when
          # the column layout depends on the widget's own width, i.e. a
          # fixed- or percent-width table (`@content_sized == false`, since a
          # given `width:` — int or `"50%"` — leaves `@width` non-nil). A
          # content-sized table's columns are content-driven and don't change
          # with the parent, so skip the full rebuild (which an interactive
          # resize drag would otherwise fire on every step). Percent-width
          # tables keep rebuilding here, as their columns do track the parent.
          unless @content_sized
            sel = selected
            set_data @rows
            selekt sel
          end
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
          sync_row_style_cache
          selected = item_selected?(item)
          item.state = selected ? WidgetState::Selected : WidgetState::Normal
          # A row never draws its own border: the table owns the outer frame and
          # `│` column separators, so a cell box painting a border would nest a
          # frame inside each cell. The non-CSS paths strip it
          # (`item_render_style`, `without_border`); the per-item CSS style must too.
          # Cached by the row's own `Style` identity (`#css_without_border`).
          base = css_without_border(item.style)
          return selection_overlay(base) if selected
          # Alternating body rows pick up the table-level
          # `alternate-background-color`, held on the normal style's
          # `alternate_row` (table-wide, independent of focus/selection), so
          # read it from there and overlay onto the row's own CSS style.
          # `alternate_row?` gates before the index lookup, so an unstyled table
          # skips it for every row. The lookup is the mixin's O(1) identity map
          # (`item_index_of`), not the O(n) `@items.index` scan, which with
          # `alternate_rows: true` would run for every row of every frame
          # (O(n²)/frame). `item_index_of` returns nil for a
          # non-item child (the pinned header, a scroll bar), so those keep
          # falling through — matching `@items.index`, and unlike a naive
          # `item.top`-as-index map, whose header `top` tracks `@child_base`.
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
      # path, memoized by source identity. Every even row shares the one
      # `style.alternate_row` object, so one derived style serves them all until
      # the cascade (or `#alternate_background=`) replaces the source.
      private def alt_row_style : Style
        src = style.alternate_row
        if (d = @_alt_row_derived) && @_alt_row_src.same?(src)
          d
        else
          @_alt_row_src = src
          @_alt_row_derived = without_border(src)
        end
      end

      # Drops the CSS-row derived-style caches when the cascade has replaced this
      # widget's styles (detected via `styles.normal`'s object identity), and —
      # so a live `#alternate_background=` still takes effect — when the
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
        @_row_wb[src]? || (@_row_wb[src] = without_border(src))
      end

      # `overlay_colors(base, source)` for a CSS even row, memoized by *base*
      # identity. *source* (`styles.normal.alternate_row`) is shared across even
      # rows and guards the cache in `#sync_row_style_cache`, so keying on *base*
      # alone is sufficient.
      private def css_alt_overlay(base : Style, source : Style) : Style
        @_row_overlay[base]? || (@_row_overlay[base] = overlay_colors(base, source))
      end

      # Sorts the body rows (the header at index 0 stays pinned) by *col*. Cells
      # that both parse as numbers compare numerically; otherwise they compare as
      # tag-stripped text. Re-applies the current sort whenever data is set.
      def sort_by_column(col : Int32, descending = false)
        @sort_column = col
        @sort_descending = descending
        # `set_data` re-applies the active sort (via `apply_sort`) over `@rows`.
        set_data @rows
      end

      # Reorders the body rows of `@rows` in place according to the current
      # `@sort_column`/`@sort_descending`, leaving the header (index 0) pinned.
      # Does NOT call `set_data` — both `sort_by_column` and the tail of
      # `set_data` call it, so calling `set_data` here would recurse forever.
      # A no-op when no sort is active or the table has at most one body row.
      private def apply_sort : Nil
        col = @sort_column
        return unless col
        return if @rows.size <= 2

        descending = @sort_descending
        head = @rows.first
        # Schwartzian transform: precompute one `{Float64?, String}` sort key per
        # body row (O(n) `clean_tags` + `to_f?`) and sort the keyed pairs, rather
        # than re-stripping tags for both operands inside the O(n log n)
        # comparator.
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
        return nil if x < 0
        # Header/rows render from `@first_col` (see `reslice_rows`), so a click
        # at relative `x == 0` lands on column `@first_col`, not column 0 —
        # accumulate the visible window from there.
        acc = 0
        (@first_col...@maxes.size).each do |i|
          acc += @maxes[i] + 1 # +1 for the inter-column separator
          return i if x < acc
        end
        @maxes.empty? ? nil : @maxes.size - 1
      end

      # Body rows draw with `style.cell` (selected rows with `styles.selected`),
      # mirroring Blessed's `style.item = style.cell` mapping (a plain `List`
      # uses `style.item`). `Style#cell` falls back to the list's own style
      # when no `cell:` is given, so the default look is unchanged.
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
      #
      # Compared against the full interior (`awidth - iwidth`) — the width the
      # columns are laid out to fill (`calculate_maxes`) — *not* `content_width`.
      # `content_width` also subtracts the *vertical* scroll bar's reserved
      # column (`content_margin_x`); when a fixed-width table scrolls vertically,
      # `row_width` fills the interior exactly, so comparing against the narrower
      # `content_width` reported a phantom 1-column horizontal overflow and drew a
      # spurious horizontal scroll bar across the bottom row.
      def really_scrollable_x?
        return false if @content_sized
        get_scroll_width > awidth - iwidth
      end

      # Scrolls horizontally by *offset* columns' worth of display columns,
      # snapping the result to a whole-column boundary (so a cell is never split
      # mid-width) and re-rendering the visible rows from the new first column.
      def scroll_x(offset = 1)
        return unless @scrollable && window?
        return if @content_sized || @maxes.empty?
        visible = content_width
        return if visible <= 0

        offsets = column_start_offsets
        max_left = Math.max(0, get_scroll_width - visible)
        max_col = column_for_offset max_left, offsets
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
          elsif @items[i]?
            # Pass the index (not the widget): `set_item(widget, …)` re-resolves
            # it with `@items.index` (O(n)) inside this per-row loop — O(n²) per
            # scroll tick. The loop already has `i`.
            set_item i, content: text
          end
        end
      end

      # Replaces the table data and rebuilds items + header.
      def set_data(rows)
        sel = @ritems[selected]?
        prev_selected = selected
        prev_count = @ritems.size

        return unless reload_rows rows

        # Re-apply the active sort over the fresh body rows so the ordering is
        # preserved across every data change, not just an explicit
        # `sort_by_column` call. Reorders `@rows` in place (no `set_data`, to
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
        # `set_data` again, which would see the old width and recurse forever.
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

        # Try to keep the previous selection. When the row count is unchanged
        # (e.g. an in-place re-sort or reslice), restore by numeric index: a
        # value-based lookup can resolve an empty/duplicate cell to the wrong
        # row — including item 0, the header spacer `""`. Fall back to the
        # value-based lookup only when the row count changed.
        if @ritems.size == prev_count && prev_selected < @ritems.size
          selekt prev_selected
        elsif sel && (i = @ritems.index(sel))
          selekt i
        else
          selekt Math.min(selected, @items.size - 1)
        end
      end

      # The header spacer (item 0) is never selectable.
      def selekt(index : Int)
        # Clamp to the first *data* row: index 0 is the header spacer
        # (`@ritems[0] == ""`, overlaid by the pinned header) and is not
        # selectable. Guarding only `== 0` let a negative index (e.g. PageUp /
        # Ctrl-B / Ctrl-U near the top, `selected - visible < 0`) slip through
        # and clamp to 0 in the parent, activating the empty header row.
        index = index.clamp(1, @items.size - 1) if @items.size > 1
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
        # the window's `_render`, before any widget renders). `set_data` pins
        # the width at construction/Attach time, but a border arriving via CSS
        # isn't folded into `style` yet then, so `iwidth` would omit the border
        # columns, leaving the box too narrow. Recomputing here converges header
        # and box edge on the first rendered frame. Assigned directly (not via
        # `width=`) to avoid the `Resize`-before-store recursion (see `set_data`).
        calculate_maxes

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

        lines = window.lines
        xi, yi, width, height = border_extent coords

        # Map visible x → actual column index, starting from the first visible
        # column so per-cell CSS recolors correctly when scrolled right.
        # Cached (see `#cached_col_for_x`) since this runs every render.
        col_map = cached_col_for_x(@first_col)

        # Only rows carrying a computed cell style need per-cell lookups; an
        # unstyled table styles only its header row via the default theme, so
        # every body row is skipped wholesale.
        @styled_rows.clear
        cells.each_key { |(r, _)| @styled_rows << r }

        y = itop
        while y < height
          # `@css_cells`/`@styled_rows` are keyed by *data-row* index (into
          # `#rows`, row 0 == header), but the body scrolls by `@child_base`, so
          # screen row `r >= 1` shows data row `r + @child_base`. Screen row 0 is
          # always the pinned header overlay (data row 0). Mapping the screen row
          # straight to the data row recolored the wrong rows once scrolled.
          screen_row = y - itop
          row = screen_row == 0 ? 0 : screen_row + @child_base
          if @styled_rows.includes?(row) && (line = lines[yi + y]?)
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

        lines = window.lines
        xi, yi, width, height = border_extent coords
        battr = sattr border
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
        (height + 1).times do
          line = lines[yi + ry]?
          break unless line

          # `rx` is the within-content column offset; the junction after column
          # `mi` is painted at `xi + ileft + rx` (content begins at the left
          # inset, not a hardcoded one column — matches
          # `TableLayout#draw_vertical_separators`).
          rx = 0
          (@first_col...last).each do |mi|
            rx += @maxes[mi]
            break if rx >= width
            if cell = line[xi + ileft + rx]?
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

        # Internal vertical separators.
        ry = 1
        while ry < height
          line = lines[yi + ry]?
          break unless line

          draw_vertical_separators line, xi, battr, start_col: @first_col, width: width

          ry += 1
        end
      end
    end
  end
end
