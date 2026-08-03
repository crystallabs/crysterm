module Crysterm
  class Widget
    class Menu
      # === Row building and layout caches ===
      #
      # The `#sync_items` rebuild pipeline and every per-frame memo it feeds:
      # visible-action snapshot, per-row text columns, fit-width/row-layout
      # caches and the render-time sizing passes. Split out of `menu.cr`
      # following the `textedit.cr`/`textedit_painting.cr` precedent.

      # Caps the auto-sized (popup/submenu) height to at most this many item rows,
      # scrolling the remainder — mirrors `ComboBox#max_visible_items`. `nil` (default)
      # fits every row. A long dropdown (e.g. a `Calendar`'s ±100 year list)
      # sets this so the popup stays on-window and scrolls to its selection.
      property max_visible_rows : Int32? = nil

      # True only while `#sync_items` is rebuilding the rows. The row rebuild
      # runs through `Mixin::ItemView#items=`, whose transient index churn
      # dispatches back into `#current_index=`; without this guard that churn
      # would see the momentarily-wrong highlight and force-close an open submenu
      # on any unrelated row rebuild (an external `action.text=`/`enabled=`, an
      # appended action, …). `#sync_items` reconciles the submenu explicitly once
      # the final rows are in place.
      @syncing_items = false

      # The item boxes that render as separator rules, rebuilt once per
      # `#sync_items`. Lets `#render_style_for` decide "is this row a
      # separator?" with an O(1) set lookup instead of a per-row scan every frame.
      @separator_items = Set(Widget).new

      # Visible-action snapshot and the per-row left/right text columns, rebuilt
      # only in `#sync_items` (i.e. on structural/visibility/label change), never
      # per frame: `#render` reaches them through
      # `#fit_width`/`#fit_height`/`#size_rows` on every frame.
      @visible_actions = [] of Action
      @row_lefts = [] of String
      @row_rights = [] of String

      # Reused scratch for the separator row-index array handed to `#dock_rows`
      # each frame, instead of a throwaway `compact_map`.
      @dock_rows_buf = [] of Int32

      # `#size_rows` dirty guard: the inner width it last laid out at, and a flag
      # set whenever the rows themselves changed (`#sync_items`). When neither
      # changed, the per-row content strings are identical, so the whole layout
      # loop (and its two allocations per row) is skipped.
      @last_laid_inner : Int32 = -1
      @rows_dirty = true

      # Depth of the active `#begin_update`/`#end_update` batch (nestable), and
      # whether a `#sync_items` was requested while batching.
      @sync_depth : Int32 = 0
      @sync_pending : Bool = false

      # Suspends row rebuilds until the matching `#end_update`. Every structural
      # edit in between coalesces into a single `#sync_items`, turning an O(A²)
      # bulk load (each `#<<` rebuilding all rows) into O(A). Nestable; a lone
      # `#<<` outside a batch still rebuilds immediately.
      def begin_update : Nil
        @sync_depth += 1
      end

      # Ends a `#begin_update` batch, running the single deferred row rebuild
      # once the outermost batch closes (and only if something requested one).
      def end_update : Nil
        @sync_depth -= 1 if @sync_depth > 0
        if @sync_depth == 0 && @sync_pending
          @sync_pending = false
          sync_items
        end
      end

      # Runs *block* inside a `#begin_update`/`#end_update` batch, flushing even
      # if it raises. (Named `batch_update`, like `Tree`'s, so the plain
      # `Widget#update` repaint-scheduler keeps its Qt meaning on menus too.)
      def batch_update(&) : Nil
        begin_update
        begin
          yield
        ensure
          end_update
        end
      end

      # Rebuilds the rows after one action's display state changed, preserving the
      # highlighted row across it (the item count can shift when visibility
      # toggles). The body every `#watch_action` handler runs.
      private def refresh_rows : Nil
        sel = current_index
        sync_items
        self.current_index = sel
        request_render
      end

      # Whether this menu auto-fits its width to its content (a popup or submenu);
      # an embedded menu given an explicit width opts out, keeping it.
      @autosize = false

      # The width that fits the rows: the widest row text plus the menu's own
      # `ihorizontal` (border + padding) and any reserved scroll-bar column. The
      # padding (`Menu { padding: 0 1 }`) is the gap between text and side
      # borders; reserving it here rather than insetting the text lets
      # `#size_rows` lay rows across the content box with padding falling outside.
      private def fit_width : Int32
        rows = @ritems.size
        fu = full_unicode?
        w = @_fit_text_width
        if w.nil? || @_fit_text_width_for != {rows, fu}
          # Display width, not codepoint count: an icon glyph (`a.icon`) or CJK/
          # emoji label is wider than its `.size`, and undersizing here would clip
          # the label.
          w = @ritems.max_of? { |r| str_width r } || (visible_actions.max_of? { |a| str_width a.text } || 8)
          @_fit_text_width = w
          @_fit_text_width_for = {rows, fu}
        end
        # A scrolling menu reserves a right-edge column for the vertical scroll
        # bar; unaccounted for, the widest row is one column too wide for the
        # drawable area and `#size_rows` wraps it onto a clipped second line.
        # `@item_pad_x` re-adds the theme's `Menu::item` horizontal padding
        # stripped from the rows themselves (see `#strip_item_box_model`).
        w + ihorizontal + content_margin_x + @item_pad_x
      end

      # Memoized widest row-text width — the per-row `str_width` scan `#fit_width`
      # would otherwise redo on every frame an auto-sized menu is visible, purely
      # to feed a change-guarded `self.width =` that is almost always a no-op.
      # `nil` means "re-measure".
      @_fit_text_width : Int32? = nil

      # What `@_fit_text_width` was measured against: the row count and the
      # grapheme-width mode `str_width` branches on (`#full_unicode?`, which flips
      # on the post-probe tier upgrade). `#sync_items` — the single structural
      # change point — and `#refresh_glyphs` drop the memo outright; this guard
      # additionally catches the inherited `ItemView#add_item`/`#insert_item`/
      # `#items=`, which can rewrite `@ritems` without passing through either.
      @_fit_text_width_for : Tuple(Int32, Bool) = {-1, false}

      # Drops the widest-row memo so the next `#fit_width` re-measures.
      private def invalidate_fit_width : Nil
        @_fit_text_width = nil
      end

      # `Mixin::ItemView` calls this from every site that writes `@ritems`, which
      # makes it the exact hook for the widest-row memo — including the in-place
      # `#set_item` and a same-size `#items=`, neither of which the row-count
      # guard in `#fit_width` can see.
      private def invalidate_item_index
        super
        invalidate_fit_width
      end

      # The height that fits the rows: one row per visible action plus the menu's
      # own `ivertical` (top/bottom border + vertical padding). Derived from
      # `ivertical` rather than a hardcoded `+ 2` so a borderless theme (e.g.
      # qdarkstyle's `QMenu { border: 0px }`) doesn't leave blank rows.
      private def fit_height : Int32
        rows = visible_actions.size
        if mv = @max_visible_rows
          rows = Math.min(rows, mv)
        end
        rows + ivertical
      end

      # Sizes a popup/submenu to fit its content. Marks the menu auto-sizing so
      # `#autosize` keeps the box correct after the cascade resolves the real box
      # model (this runs pre-cascade for a freshly-opened submenu).
      protected def fit_to_content : Nil
        @autosize = true
        self.width = fit_width
        self.height = fit_height
      end

      # Re-fits an auto-sized menu's box at render, once the cascade has set the
      # real box model — `#fit_to_content` runs before that for a submenu, so it
      # can miss it. Corrects both dimensions, growing rightward/down from a fixed
      # top-left anchor. No-op for an explicitly-sized embedded menu.
      private def autosize : Nil
        return unless @autosize
        w = fit_width
        self.width = w unless width == w
        h = fit_height
        self.height = h unless height == h
      end

      # Lays each row's text out across the menu's full inner width: the checkbox
      # slot + label flush-left, the shortcut/▶ column flush-right (at the border),
      # the theme's breathing reserved by `#fit_to_content` falling between them.
      # Done at render because that is the first point the final width is known.
      private def size_rows : Nil
        # `content_width`, not `awidth - ihorizontal`: a scrolling menu reserves a
        # right-edge scroll-bar column (`content_margin_x`), so laying rows to the
        # full inner width sizes them one column too wide and wraps the text onto
        # a clipped second line.
        inner = content_width
        return if inner < 1
        acts = @visible_actions
        return unless acts.size == @item_boxes.size
        # The per-row content is a pure function of `inner` and the cached
        # `@row_lefts`/`@row_rights`, so an unchanged frame would rebuild
        # identical strings only for `set_content` to no-op them.
        return if inner == @last_laid_inner && !@rows_dirty
        lefts = @row_lefts
        rights = @row_rights
        @item_boxes.each_with_index do |it, i|
          next if @separator_items.includes? it
          l = lefts[i]
          r = rights[i]
          # Display width, not codepoint count: an icon/CJK label would otherwise
          # over-pad and push the right-aligned shortcut/▶ past the border.
          pad = inner - str_width(l) - str_width(r)
          content = pad >= 1 ? "#{l}#{" " * pad}#{r}" : head_within("#{l}#{r}", inner)
          it.set_content(content) unless it.content == content
        end
        @last_laid_inner = inner
        @rows_dirty = false
      end

      # Renders the menu, then docks its separator rules to the vertical borders
      # so each reads as `├────┤` rather than a detached dash. Reuses the
      # window's border-docking component (`#dock_rows`); runs after `super`
      # so it re-applies the junctions each frame the border is repainted.
      def render(with_children = true)
        refresh_glyphs
        strip_item_box_model
        autosize
        size_rows
        size_separators
        ret = super
        unless @separator_items.empty?
          buf = @dock_rows_buf
          buf.clear
          @separator_items.each do |itm|
            if yi = itm.@lpos.try &.yi
              buf << yi
            end
          end
          dock_rows buf
        end
        ret
      end

      # Strips the `QMenu::item` `padding`/`border` from every row's computed
      # style, in place, before rows lay out. A row's content box then spans its
      # full width, so text — the `[x] ` prefix, label, right-aligned shortcut/▶ —
      # sits flush against the borders; those columns are realized by row text,
      # not literal padding. Colors (`background`, `:selected`) stay.
      #
      # The stripped horizontal padding is not lost: its widest value is
      # recorded in `@item_pad_x` and re-added by `#fit_width`, so a theme's
      # `Menu::item { padding: … }` still widens the popup (Qt's roomy menu
      # look — without it a border-less themed menu collapses to bare text and
      # reads as transparent against what's underneath). `#size_rows` realizes
      # the room as the gap between the flush-left label and the right-aligned
      # shortcut column. Item styles are stable objects between cascades and
      # this strip zeroes them in place, so the measurement is only trusted
      # when the cascade has minted fresh styles (identity change on the probe
      # row); vertical item padding stays collapsed — sub-cell in practice.
      private def strip_item_box_model : Nil
        probe = @item_boxes.find { |it| !@separator_items.includes? it }
        fresh = if probe
                  gen = probe.styles.normal.object_id
                  changed = gen != @item_pad_for
                  @item_pad_for = gen
                  changed
                else
                  false
                end
        pad = 0
        @item_boxes.each do |it|
          next if @separator_items.includes? it
          st = it.styles.normal
          pad = Math.max pad, st.padding.left + st.padding.right
          strip_box_model st
          strip_box_model it.styles.selected if it.styles.own_selected?
        end
        @item_pad_x = pad if fresh
      end

      # Widest horizontal `Menu::item` padding of the current item styles,
      # reserved back into `#fit_width` (see `#strip_item_box_model`).
      @item_pad_x = 0

      # Identity of the probe row's style the reserve was measured from; a
      # cascade re-run (or theme switch) mints new style objects, changing it.
      @item_pad_for : UInt64 = 0_u64

      private def strip_box_model(st : Style) : Nil
        st.padding = Padding.new(0) if st.padding.any?
        st.border = false if st.border.any?
      end

      # Stretches each separator's `─` rule across the menu's full inner width,
      # sized at render because that's the first point the final width is known.
      # A separator carries no item padding (not tagged `Item`), so it spans the
      # whole content area and, via `#dock_rows`, joins the borders as `├────┤`.
      private def size_separators : Nil
        return if @separator_items.empty?
        inner = awidth - ihorizontal
        return if inner < 1
        ch = separator_char
        @separator_items.each do |it|
          # Rewrite on a width *or* glyph change (a stylesheet's
          # `Menu::separator { glyph }`, `Glyphs.set`, a tier switch).
          c = it.content
          it.set_content(ch.to_s * inner) unless c.size == inner && c.starts_with?(ch)
        end
      end

      # The separator rule's character: CSS `Menu::separator { glyph: … }`,
      # then the registry. A cell role — `none`/wide values fall back.
      private def separator_char : Char
        glyph(Glyphs::Role::LineHorizontal, style.raw_sub_style("separator"))
      end

      # Everything the cached row texts' glyphs resolve from. When it drifts
      # from the `@_glyph_key` stamped by `#sync_items` — a registry retheme,
      # a tier switch, or a cascade that (re)set the submenu-arrow/separator
      # glyphs — the rows are rebuilt, since a glyph change moves column widths.
      # Builds on the shared `WidgetContent#glyph_key` base triple, folding in the
      # two sub-style glyphs the rows also bake in (submenu-arrow indicator,
      # separator rule).
      private def row_glyph_key : { {String?, Glyphs::Tier, UInt64}, String?, String? }
        tier = glyph_tier
        {glyph_key,
         style.raw_sub_style("indicator").try(&.glyph_for(tier)),
         style.raw_sub_style("separator").try(&.glyph_for(tier))}
      end

      # :ditto:
      @_glyph_key : { {String?, Glyphs::Tier, UInt64}, String?, String? }?

      # Rebuilds the row texts when the resolved glyphs changed out from under
      # them (see `#row_glyph_key`); a no-op on the steady-state frame.
      private def refresh_glyphs : Nil
        return if @_glyph_key == row_glyph_key
        # A glyph/tier change moves display widths too (`str_width` branches on
        # `#full_unicode?`), so the widest-row memo goes with the row texts.
        invalidate_fit_width
        sync_items
      end

      # The visible actions, in display order. Cached: rebuilt only in
      # `#sync_items` (structural / visibility / label change), never per frame.
      # Callers must treat the returned array as read-only.
      private def visible_actions : Array(Action)
        @visible_actions
      end

      # The left (checkbox slot + label) and right (shortcut / ▶) text columns
      # for each visible action; separators get empty entries. The check column is
      # *measured*: its width is the widest state's composed `[x]` marker plus a
      # gap, shared by every row so labels start at a consistent column — and it
      # vanishes entirely when no item is checkable.
      private def row_columns(acts : Array(Action)) : {Array(String), Array(String)}
        tier = glyph_tier
        # The check marks are registry-resolved (a menu's check column has no
        # per-item CSS site; `Menu::indicator` is the submenu arrow below).
        open = Glyphs[Glyphs::Role::CheckboxOpen, tier]
        close = Glyphs[Glyphs::Role::CheckboxClose, tier]
        base = Unicode.width(open) + Unicode.width(close)
        marker_w = base + Math.max(
          Unicode.width(Glyphs[Glyphs::Role::CheckboxChecked, tier]),
          Unicode.width(Glyphs[Glyphs::Role::CheckboxUnchecked, tier]))
        column = acts.any? { |a| !a.separator? && a.checkable? } ? marker_w + 1 : 0
        lefts = acts.map do |a|
          next "" if a.separator?
          prefix = if column == 0
                     ""
                   elsif a.checkable?
                     mark = Glyphs[a.checked? ? Glyphs::Role::CheckboxChecked : Glyphs::Role::CheckboxUnchecked, tier]
                     # Pad a narrower state's marker to the shared column width
                     # (the trailing gap is part of the column).
                     "#{open}#{mark}#{close}#{" " * (column - base - Unicode.width(mark))}"
                   else
                     " " * column
                   end
          icon = (i = a.icon) ? "#{i} " : ""
          "#{prefix}#{icon}#{a.text}"
        end
        # Submenu arrow: CSS `Menu::indicator { glyph: … }`, then the registry;
        # `glyph: none` drops the arrow column for those rows.
        arrow = glyph?(Glyphs::Role::SubmenuArrow, style.raw_sub_style("indicator"))
        rights = acts.map do |a|
          next "" if a.separator?
          next (arrow ? arrow.to_s : "") if a.menu?
          a.shortcut_text
        end
        {lefts, rights}
      end

      # Rebuilds the list rows from the visible actions. Each row's text holds
      # the full column layout (checkbox slot + label, then shortcut/▶), and
      # `#size_rows` stretches it to the final width at render. Separators are a
      # placeholder here, sized by `#size_separators`.
      private def sync_items
        # Batched (`#begin_update`): record that a rebuild is owed and let the
        # matching `#end_update` run it once, instead of once per edit.
        if @sync_depth > 0
          @sync_pending = true
          return
        end

        # This is the single structural-change point, so the cached
        # visible-action snapshot and per-row text columns refresh here and the
        # per-frame render path reads them without recomputing. The row layout is
        # marked dirty so the next `#size_rows` re-lays even at an unchanged
        # width, and the glyph key is stamped for `#refresh_glyphs`.
        @_glyph_key = row_glyph_key
        acts = @visible_actions = @actions.select &.visible?
        lefts, rights = row_columns(acts)
        @row_lefts = lefts
        @row_rights = rights
        @rows_dirty = true

        rows = acts.map_with_index do |a, i|
          if a.separator?
            separator_char.to_s
          else
            row = lefts[i]
            row += "  " + rights[i] unless rights[i].empty?
            row
          end
        end

        # Suppress `#current_index=`'s submenu-close check for the duration of the
        # row rebuild: `items=` transiently moves the cursor while reusing/adding/
        # removing boxes, and each hop dispatches into `#current_index=`. The
        # submenu is reconciled once, below, against the final `@visible_actions`.
        @syncing_items = true
        begin
          self.items = rows
        ensure
          @syncing_items = false
        end

        # After `items=` has rewritten `@ritems`, not before it: measuring off a
        # half-updated `@ritems` could cache old widths under a row count that
        # happens to match the new one.
        invalidate_fit_width

        # Rebuild the separator-row lookup from the just-built rows: `#items=`
        # leaves `@item_boxes[i]` corresponding to `acts[i]`, so a separator action's
        # row is the same-index item. Non-separator rows are tagged with the
        # `Item` CSS class so they're styled as the menu's `::item` sub-control
        # (Qt's rows aren't independent widgets but the menu's `::item`, which
        # inherits the menu surface and takes its highlight from
        # `QMenu::item:selected`) rather than falling through to generic
        # `QWidget` rules and mismatching the frame.
        @separator_items = Set(Widget).new
        @item_boxes.each_with_index do |itm, i|
          if (a = acts[i]?) && a.separator?
            @separator_items << itm
          else
            itm.add_css_class "Item"
          end
        end

        # Reconcile an open submenu against the freshly-rebuilt rows. The per-hop
        # close check was suppressed via `@syncing_items` during `items=`, so
        # decide here, once, with the final `@visible_actions`: if the submenu's
        # action was removed or hidden it can no longer be anchored — close the
        # submenu; otherwise its row may have shifted, so re-anchor
        # `@submenu_anchor` to the action's current item box so the outside-click
        # watcher keeps tracking the right row.
        if act = @submenu_action
          if idx = @visible_actions.index act
            @submenu_anchor = @item_boxes[idx]?
          else
            close_submenu
          end
        end
      end
    end
  end
end
