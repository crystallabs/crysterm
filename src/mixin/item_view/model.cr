module Crysterm
  module Mixin
    module ItemView
      # Index of the currently-selected item (Qt's `QAbstractItemView`
      # `currentIndex`). Read-only here: assignment must route through
      # `#current_index=`, which clamps to the list, steps over
      # non-selectable rows, refreshes `#current_text`, scrolls the item into
      # view and emits `Event::ItemSelected`. A plain setter does none of that
      # and leaves the widget internally inconsistent.
      def current_index : Int32
        @selected
      end

      # :ditto:
      def current_index=(index : Int) : Nil
        return unless interactive?
        return if @selection_mode.no_selection?

        if @item_boxes.empty?
          @selected = 0
          @value = ""
          # Clear the latch so re-populating the list re-runs the body below.
          # Otherwise emptying a list leaves `@selected == 0` AND
          # `@_list_initialized == true`, so `add_item`'s `self.current_index = 0` for the
          # first new row hits the unchanged-index short-circuit and skips
          # refreshing `@value`/emitting `ItemSelected`.
          @_list_initialized = false
          scroll_to 0
          return
        end

        # Step the cursor over any non-selectable divider rows, in the direction
        # of travel (moving down past a separator lands on the next real row;
        # moving up, the previous one). No-op unless `#non_selectable_rows` is set.
        unless @nonselectable.empty?
          dir = index >= @selected ? 1 : -1
          if adj = nearest_selectable_row(index.to_i, dir)
            index = adj
          end
        end

        # The `@ritems[@selected]` read below relies on the
        # `@item_boxes.size == @ritems.size` invariant every mutator maintains.
        index = index.clamp(0, @item_boxes.size - 1)

        return if @selected == index && @_list_initialized
        @_list_initialized = true

        @selected = index
        @value = clean_tags @ritems[@selected]

        # Gate on having been laid out, not on having a `#parent`: a top-level
        # widget appended straight to a `Window` has no `#parent`, so an
        # `unless @parent` guard would silently skip `scroll_to`/`ItemSelected` for
        # window-level lists. `@lpos` is nil only until the first render.
        return unless @lpos

        # Scroll to the item's *content row*, not its bare index: with
        # `item_spacing > 0` the item sits at
        # `item_row(@selected) == @selected * (1 + item_spacing)`, so
        # `scroll_to @selected` lands `@selected * item_spacing` rows short.
        scroll_to item_row(@selected)

        emit ::Crysterm::Event::ItemSelected, @item_boxes[@selected], @selected
      end

      # Number of items in the view (Qt's `QListWidget#count`). Answered across the
      # item-view family, so callers never have to know which internal array
      # (`items`/`ritems`/`roots`/`actions`) a given widget happens to keep.
      def count : Int32
        @item_boxes.size
      end

      # Blank rows of vertical spacing inserted *between* items (Qt's
      # `QListView` spacing). Gaps aren't items — nothing to click/select there.
      # `0` (default) stacks items flush.
      getter item_spacing : Int32 = 0

      # Re-places existing items when the spacing changes at runtime.
      def item_spacing=(value : Int32) : Int32
        @item_spacing = value
        @item_boxes.each_with_index { |it, i| it.top = item_row(i) }
        value
      end

      # The content row an item at *index* occupies, accounting for the gaps
      # before it. With spacing `0` this is just *index*.
      private def item_row(index : Int) : Int32
        index * (1 + @item_spacing)
      end

      # The item index whose box occupies content *row* — the inverse of
      # `#item_row`, flooring a gap row onto the item above it. With spacing `0`
      # this is just *row*. Use it wherever a viewport/content *row* must be
      # mapped back to an item *index* (vi_keys H/M/L, wheel scroll, hover clamp):
      # treating `@child_base` as an index conflates the two once spaced.
      private def item_at_row(row : Int) : Int32
        return row if @item_spacing.zero?
        row // (1 + @item_spacing)
      end

      # How many whole items fit in the visible viewport, accounting for
      # inter-item gaps — the natural unit for half/page navigation moves (which
      # step by *items*, not rows). At least 1.
      private def items_per_page : Int32
        Math.max(1, visible_content_rows // (1 + @item_spacing))
      end

      # Floors *base* to the last item's spaced content row: the "spaced extent"
      # both `#scroll_height` and `#scroll_extent_bottom` need over their own
      # `super`. Returns *base* unchanged when unspaced or empty.
      private def spaced_extent(base : Int32) : Int32
        return base if @item_spacing.zero? || @item_boxes.empty?
        Math.max(base, item_row(@item_boxes.size - 1) + 1)
      end

      # Total content height in rows, including inter-item gaps, so scrollbar/
      # overflow logic sees the real extent (`scroll_extent_bottom` otherwise counts
      # items, ignoring spacing). Unchanged when not spaced.
      def scroll_height : Int32
        spaced_extent super
      end

      # Spaced extent for the scroll clamp/thumb. The base `scroll_extent_bottom`
      # returns `@item_boxes.size` for lists, ignoring `item_spacing`, which reins
      # `clamp_child_base_to_content` in too far and hides the last item(s) of a
      # spaced, overflowing list; report the same spaced height as
      # `#scroll_height` so the clamp reaches the true bottom.
      protected def scroll_extent_bottom
        spaced_extent super
      end

      # Whether the view is in `SelectionMode::MultiSelection`. A derived query,
      # not a stored flag — assign `#selection_mode` to change it.
      def multi_select? : Bool
        @selection_mode.multi_selection?
      end

      # Row indices that behave as non-selectable dividers: the selection cursor
      # steps *over* them (arrow/paging keys land on the nearest real row beyond)
      # and a click or Enter on one does nothing. Empty by default, so the skip
      # logic is a no-op until a host marks rows. Set it *after* `#items=`: a
      # wholesale replace does not clear it, since row *meaning* is the host's.
      def non_selectable_rows : Set(Int32)
        @nonselectable
      end

      # Marks *indices* as non-selectable dividers (see `#non_selectable_rows`).
      def non_selectable_rows=(indices : Enumerable(Int32)) : Nil
        @nonselectable = indices.to_set
      end

      # The nearest selectable row to *index*, stepping in *dir* (`+1` forward,
      # `-1` back) over any `#non_selectable_rows` dividers; *index* itself when it is
      # already selectable or nothing is marked. `nil` only if every row is a
      # divider, in which case the caller keeps the raw index.
      private def nearest_selectable_row(index : Int32, dir : Int32) : Int32?
        return index if @nonselectable.empty?
        Mixin::NavKeys.nearest_selectable(@item_boxes.size, index, dir) { |i| @nonselectable.includes? i }
      end

      # Tag-stripped text of the currently selected item (`""` when empty),
      # Qt's `currentText`. Kept in sync by `#current_index=`.
      def current_text : String
        @value
      end

      # Tag-stripped text of every multi-selected item, in row order. In
      # single-selection mode this is just `[value]` (or `[]` when empty).
      def selected_values : Array(String)
        unless multi_select?
          # Empty list has no selection: report `[]`, not `[""]` (wrapping
          # `@value` would surface a phantom one-element selection).
          return [] of String if @item_boxes.empty?
          return [@value]
        end
        @selected_indices.to_a.sort.compact_map { |i| @ritems[i]?.try { |r| clean_tags r } }
      end

      # Adds *index* to the multi-selection. A no-op unless `#multi_select?` —
      # deliberately, rather than falling back to `#current_index=`, which would
      # leave it asymmetric with `#remove_from_selection`/`#toggle_selection`
      # (neither of which has a single-selection meaning).
      def add_to_selection(index : Int)
        return unless multi_select?
        return unless 0 <= index < @item_boxes.size
        if @selected_indices.add?(index)
          emit ::Crysterm::Event::ItemSelected, @item_boxes[index], index
        end
      end

      # Removes *index* from the multi-selection.
      def remove_from_selection(index : Int)
        @selected_indices.delete index
      end

      # Flips *index*'s membership in the multi-selection.
      def toggle_selection(index : Int)
        return unless multi_select?
        @selected_indices.includes?(index) ? remove_from_selection(index) : add_to_selection(index)
      end

      # Clears the whole multi-selection.
      def clear_selection
        @selected_indices.clear
      end

      # *right* defaults to `#content_margin_x` (vertical bar width, reserved
      # only when shown) as the item's *initial* value; `#render` re-syncs it
      # every frame. The horizontal bar reserves a bottom row via
      # `#hscrollbar_rows` instead, so nothing is taken off the right for it.
      protected def create_item(content : String, window = ::Crysterm::Window.global, align : ::Tput::AlignFlag | Shorthands = @align, top = 0, left = 0, right = content_margin_x, parse_tags = @parse_tags, focus_on_click = false, normal_resizable = false, width = nil) # XXX hover_effects, focus_effects

        if @shrink_to_fit || normal_resizable
          right = nil
        end

        # Items must not carry the list's border in their *layout* either:
        # `#item_render_style` strips it for drawing, but a border left on the
        # item's own style still reserves `ihorizontal`, shrinking the content area
        # (e.g. a tight popup menu showing "Abo" instead of "About"). Give items
        # a borderless base style so geometry matches.
        item_style = style
        item_style = without_border item_style if item_style.border.any?
        # An item's own style must not carry the list's *hidden* state: a style
        # captured while the list is hidden keeps `visible: false` and never
        # reappears when shown (e.g. menu rows added after `hide`). Dup only if
        # still pointing at the list's own style, so this never flips the list
        # itself visible.
        item_style = item_style.dup if item_style.same?(style)
        item_style.visible = true

        # Items are always 1 row tall: `#item_row`/`#item_at_row`/`#items_per_page`
        # all assume a single-row item, so height is fixed here (not a parameter).
        item = Widget::Box.new(content: content, window: window, align: align, top: top, left: left, right: right, parse_tags: parse_tags, height: 1, focus_on_click: focus_on_click, width: width, style: item_style)

        if mouse?
          # Default: click selects, clicking the already-selected one activates.
          # `#activate_on_click?` makes a single click both select and activate.
          item.on(::Crysterm::Event::Click) do
            if (i = item_index_of item) && !@nonselectable.includes?(i)
              # Honor the list's own `#focus_on_click?` opt-out, as automatic
              # click-to-focus does. A focus-declining list (e.g. a `Completer`
              # drop-down, whose owning text box must keep focus so typing keeps
              # filtering) would otherwise be pulled into focus here — blurring
              # the box, tearing down its read mode, and leaving it
              # focused-but-uneditable.
              focus if focus_on_click?
              if activate_on_click? || i == @selected
                activate_item i
              else
                self.current_index = i
              end
              request_render
            end
          end

          # Wheel over a row scrolls the list; `#accept`s so the window's default
          # scroll-the-view behavior doesn't also fire. Routed through
          # `#wheel_scroll` so a subclass can give the wheel its own semantics
          # without disturbing the arrow-key path.
          item.on(::Crysterm::Event::Mouse) do |e|
            if e.action.wheel_up?
              wheel_scroll -1
              e.accept
              request_render
            elsif e.action.wheel_down?
              wheel_scroll 1
              e.accept
              request_render
            end
          end

          # With `#hover_select?`, moving onto a row highlights it via the
          # overridable `#hover_item`.
          if hover_select?
            item.on(::Crysterm::Event::MouseEnter) do
              if i = item_index_of item
                hover_item i
                request_render
              end
            end
          end
        end

        item
      end

      # Appends an item showing *content* and returns its box (Qt's
      # `QListWidget#addItem`).
      #
      # `protected`, like every raw row mutator here (`#insert_item`,
      # `#remove_item`, `#set_item`, `#items=`, `#clear`, `#<<`): these edit the
      # raw row model, which only `Widget::List` (and `ComboBox::Popup`) *own* —
      # `List` re-publicizes them. On the model-backed views (`Tree`,
      # `ListTable`, `Menu`, `FileManager`, `TocView`) the rows are re-derived
      # from the real model on every rebuild, so a raw row added from user code
      # would be silently wiped; those views expose their own verbs
      # (`Tree#add`, `ListTable#rows=`, `Menu#add_action`) instead. In-tree
      # code (same top-level namespace) can still call these — that is how the
      # views' own rebuilds and `Reactive.bind_items` are implemented.
      protected def add_item(content : String)
        item = create_item content
        item.top = item_row(@item_boxes.size)

        @ritems.push content
        invalidate_item_index
        @item_boxes.push item
        append item

        if @item_boxes.size == 1
          self.current_index = 0
        end

        emit ::Crysterm::Event::ItemAdded

        item
      end

      # :ditto:
      protected def add_item(widget : Widget)
        add_item widget.rendered_content
      end

      # `#<<` is an operator alias for `#add_item`, e.g. `list << "Item"`.
      #
      # Only the `String` overload may take an operator. `Mixin::Children#<<`
      # appends a *child widget*, and the two coexist only because this one is
      # typed to `String`: `view << some_widget` appends a child, `view << "text"`
      # appends an item. Deliberately written out rather than aliased via
      # `alias_method`, which copies *every* overload's restrictions — the
      # `#add_item(widget : Widget)` overload would then yield a `#<<(Widget)`
      # matching `Mixin::Children#<<` exactly, win on ancestor distance, and
      # silently turn child-appends into item-appends.
      protected def <<(content : String)
        add_item content
        self
      end

      # Removes the item at *child* — a row index, an item's text, or the item
      # box itself — and returns its box (`nil` when *child* resolves to no item).
      # Row-based, like Qt's `QListWidget#takeItem`.
      # `protected` — see `#add_item`.
      protected def remove_item(child)
        i = index_of child
        return unless i

        item = @item_boxes[i]?
        if item
          @item_boxes.delete_at i
          @ritems.delete_at i
          invalidate_item_index
          remove item
        end

        (i...@item_boxes.size).each { |j| @item_boxes[j].top = item_row(j) }

        # Keep the multi-selection aligned: drop the removed index, slide
        # everything past it down by one.
        if @selected_indices.includes?(i) || @selected_indices.any? { |s| s > i }
          @selected_indices = shift_index_set(@selected_indices, i, -1, drop_at: true)
        end

        # Keep the divider set aligned the same way — otherwise a marker keeps
        # pointing at a stale row once a row before it is removed (see
        # `#non_selectable_rows=`).
        if @nonselectable.includes?(i) || @nonselectable.any? { |s| s > i }
          @nonselectable = shift_index_set(@nonselectable, i, -1, drop_at: true)
        end

        # Keep the single-selection cursor on the same logical item: removing a
        # row before the cursor shifts later rows down by one, so the cursor
        # slides too. Otherwise `@selected` jumps to the next item or points past
        # the end. Removing the selected row itself selects the row before it.
        if i < @selected
          self.current_index = @selected - 1
        elsif i == @selected
          # When the removed row was first (`i == 0`), the cursor stays at index
          # 0 (now holding the next row) — same `@selected` value, so
          # `#current_index=`'s unchanged-index short-circuit would skip refreshing
          # `@value`/emitting `ItemSelected`. Clear the latch to force a full
          # re-run. No-op for `i > 0`, where the index actually changes.
          @_list_initialized = false
          self.current_index = i - 1
        end

        emit ::Crysterm::Event::ItemRemoved

        item
      end

      # `#>>` is an operator alias for `#remove_item`, mirroring `#<<`.
      alias_method :>>, :remove_item

      # The item box at *child* — a row index, an item's text, or the box itself
      # — or `nil` when it resolves to no item (Qt's `QListWidget#item(row)`).
      def item(child)
        i = index_of child
        return unless i
        @item_boxes[i]?
      end

      # Index of *child* (a row index, an item's text, or the item box itself),
      # or `nil` when the view holds no such item — like `Array#index`.
      #
      # The `Int` form validates rather than handing its argument back (the
      # shared `Mixin::IndexValidation` body), so an out-of-range row
      # (`set_item 999, "x"`) is caught here instead of silently no-op'ing at
      # the call site.
      def index_of(child : Int) : Int32?
        validated_index child, @item_boxes.size
      end

      # :ditto:
      def index_of(child : String) : Int32?
        # Exact (raw, tags-included) match takes priority.
        i = @ritems.index child
        return i if i

        # Fallback: match against tag-stripped form. The cleaned->index map is
        # built once and reused until `@ritems` changes, instead of re-cleaning
        # every item per call. First index wins.
        index = @clean_tags_index ||= begin
          h = {} of String => Int32
          @ritems.each_with_index do |item, idx|
            cleaned = clean_tags item
            h[cleaned] = idx unless h.has_key? cleaned
          end
          h
        end
        index[child]?
      end

      # Realigns an index set (`@selected_indices` or `@nonselectable`) after a
      # row is inserted/removed at *at*. *delta* is `-1` for a removal, `+1` for
      # an insertion; *drop_at* discards an index sitting exactly *at* the
      # removed row (irrelevant for insertion, where nothing is dropped).
      # Shared by `#remove_item` and `#insert_item` so the multi-selection and
      # the divider set can't drift apart from each other again.
      private def shift_index_set(set : Set(Int32), at : Int32, delta : Int32, drop_at : Bool) : Set(Int32)
        set.compact_map do |s|
          next if drop_at && s == at
          s >= at ? s + delta : s
        end.to_set
      end

      # Drops the cached `clean_tags` index so it's rebuilt fresh next lookup.
      # Called from every method that mutates `@ritems`.
      private def invalidate_item_index
        @clean_tags_index = nil
        @item_index = nil
      end

      # O(1) index of item widget *item* in `@item_boxes` (nil when absent), via the
      # lazily-built `@item_index` map. Same result as `@item_boxes.index item`,
      # without the per-item linear scan on the hot render path.
      private def item_index_of(item : Widget) : Int32?
        index = @item_index ||= begin
          h = {} of Widget => Int32
          @item_boxes.each_with_index { |it, i| h[it] = i }
          h
        end
        index[item]?
      end

      # :ditto: — accepts any `Widget`, not only `Widget::Box`.
      def index_of(child : Widget) : Int32?
        item_index_of child
      end

      # Removes every item (Qt's `QListWidget#clear`).
      # `protected` — see `#add_item`.
      protected def clear
        self.items = [] of String
      end

      # Inserts an item showing *content* at row *index* (Qt's
      # `QListWidget#insertItem`). *index* == `#count` appends, so this does not
      # route through `#index_of`, which validates against the *existing* rows.
      # `protected` — see `#add_item`.
      protected def insert_item(index : Int, content : String)
        i = index.to_i
        return unless 0 <= i <= @item_boxes.size
        if i == @item_boxes.size
          return add_item content
        end
        item = create_item content
        # Slide multi-selected indices at/after the insertion point up by one.
        if @selected_indices.any? { |s| s >= i }
          @selected_indices = shift_index_set(@selected_indices, i, 1, drop_at: false)
        end

        # Same slide for the divider set, so a marked row keeps pointing at the
        # same logical row instead of a row that shifted out from under it.
        if @nonselectable.any? { |s| s >= i }
          @nonselectable = shift_index_set(@nonselectable, i, 1, drop_at: false)
        end
        item.top = item_row(i)
        # The inserted item shifts every later row down one slot; re-place them.
        (i...@item_boxes.size).each { |j| @item_boxes[j].top = item_row(j + 1) }
        @ritems.insert i, content
        invalidate_item_index
        @item_boxes.insert i, item
        append item
        # Keep the single-selection cursor on the same logical item: inserting
        # at or before the cursor shifts it down by one too, mirroring the
        # multi-selection slide above (`s >= i`) and the realignment `remove_item`
        # performs. Must check `i <= selected`, not just `i == selected`, or an
        # insert before the cursor leaves `@selected`/`@value` stale.
        if i <= @selected
          self.current_index = @selected + 1
        end
        emit Crysterm::Event::ItemInserted
      end

      # :ditto: — *child* is an existing item's text or box; the new item takes
      # its row.
      protected def insert_item(child : String | Widget, content : String)
        i = index_of child
        return unless i
        insert_item i, content
      end

      # Replaces the text of the item at *child* (a row index, an item's text, or
      # the item box itself). No-op when *child*
      # resolves to no item, including an out-of-range row.
      # `protected` — see `#add_item`.
      protected def set_item(child, content : String)
        i = index_of child
        return unless i

        @item_boxes[i]?.try &.set_content(content)
        if i < @ritems.size
          @ritems[i] = content
          invalidate_item_index
          # Keep cached `#value` in sync when the *selected* row's text changes
          # in place — `#current_index=` early-returns on an unchanged index, so it
          # wouldn't otherwise refresh `@value`.
          @value = clean_tags(content) if i == @selected
        end
      end

      # :ditto:
      protected def set_item(child, widget : Widget)
        set_item child, content: widget.rendered_content
      end

      # Replaces every item with one per entry of *items* (reusing the existing
      # boxes where it can) and emits `Event::ItemsChanged`. The inverse of
      # `#items` (the text model); the backing boxes are `#item_boxes`.
      # `protected` — see `#add_item`.
      protected def items=(items : Array(String))
        # Wholesale replacement: stale indices can't be carried over, so drop
        # the multi-selection.
        @selected_indices.clear
        original = @item_boxes.dup
        previous = @selected
        sel = @ritems[previous]?

        # Quietly reset the internal cursor to the top *without* emitting
        # `ItemSelected` or scrolling — the real selection is restored by the
        # single `current_index=` call at the end. Doing an actual
        # `self.current_index = 0` here would take the full setter path on a
        # rendered list (`@lpos` non-nil) with a non-zero selection: it would
        # scroll to row 0 and emit an `ItemSelected` carrying the *old* row-0
        # item, only to be immediately overwritten by the restore below.
        # Clearing the latch mirrors `current_index=`'s empty branch so the final
        # restore call runs fully instead of hitting the unchanged-index
        # short-circuit (the same reason `add_item`/`remove_item` clear it).
        @selected = 0
        @_list_initialized = false

        items.each_with_index do |item, i|
          if itm = @item_boxes[i]?
            itm.set_content item
          else
            add_item item
          end
        end

        # Remove only the *leftover* original items (past the end of the new
        # list) — the first `items.size` were reused above via `set_content`.
        # Must be `remove_item`, not `remove`: `remove` only unlinks from the
        # children tree, leaving `@item_boxes`/`@ritems` with stale entries.
        #
        # Removed by *index*, from the end — not by widget, head-first. Passing
        # the box would route through `#index_of(Widget)`, whose `@item_index`
        # map `#remove_item` nils on every removal, so a wholesale replace
        # rebuilt the whole O(n) identity map once per dropped row. The `Int`
        # form validates in O(1) instead, and removing the *last* row leaves
        # `#remove_item`'s tail re-place loop empty. End state is identical:
        # `@selected_indices` was cleared above, `@nonselectable` ends up with
        # exactly its sub-`items.size` entries either way (tail-first drops each
        # leftover index in place; head-first slides them down onto `items.size`
        # and drops them there), and with `@selected == 0` every `i >= items.size`
        # skips both cursor branches — except an emptying replace, whose final
        # `i == 0` removal takes the same branch today's first iteration does.
        # Only `Event::ItemRemoved` now fires tail-first (no listener orders on
        # it; wholesale-replace consumers watch the single `ItemsChanged`).
        if original.size > items.size
          (original.size - 1).downto(items.size) do |j|
            remove_item j
          end
        end

        # `dup`, not a bare alias: the list mutates `@ritems` in place on every
        # append/insert/remove. Storing the caller's array directly would leak
        # those mutations back into it (and vice versa). `to_a` would NOT do —
        # `Array#to_a` returns `self`.
        @ritems = items.dup
        invalidate_item_index

        # Try to find our old item if it still exists
        if sel
          sel = items.index sel
          if sel
            self.current_index = sel
          elsif @item_boxes.size == original.size
            # Use the saved selection; `selected` was just reset to 0 above.
            self.current_index = previous
          else
            self.current_index = Math.min previous, @item_boxes.size - 1
          end
        end

        # Rows were reused in place above, so the selection may land on the same
        # index whose text just changed — `current_index=`'s unchanged-index
        # short-circuit wouldn't refresh `@value`. Sync it explicitly. `""` when
        # the list ended up empty.
        @value = @ritems[@selected]?.try { |r| clean_tags r } || ""

        emit Crysterm::Event::ItemsChanged
      end

      # Selects the item at *index* and activates it. A click lands on a raw row
      # index; ignore it on a divider (a bare `current_index = index` would skip
      # onto a neighbor and fire *its* action). Keyboard Enter is unaffected —
      # `current_index=` never rests the cursor on a divider.
      def activate_item(index : Int32)
        return if @nonselectable.includes? index
        self.current_index = index
        activate_current
      end

      # Activates the current item (Qt's `QAbstractItemView#activated`), emitting
      # `Event::ItemActivated`.
      #
      # Activation is NOT a selection change, so it must not emit
      # `Event::ItemSelected`: `#current_index=` already emits that, and adding one
      # here fires it twice per Enter while the selection has not moved at all.
      def activate_current
        # `item_boxes[@selected]` raises `IndexError` on an empty list under
        # Crystal's strict indexing.
        return if @item_boxes.empty?
        emit Crysterm::Event::ItemActivated, @item_boxes[@selected], @selected
      end

      # Selects the item at *index* and cancels it (Escape).
      def cancel_item(index : Int32)
        self.current_index = index
        cancel_current
      end

      # Cancels the current item, emitting both `Event::ItemActivated` and
      # `Event::ItemCancelled`.
      def cancel_current
        # See `#activate_current`: guard against `IndexError` on an empty list.
        return if @item_boxes.empty?
        emit Crysterm::Event::ItemActivated, @item_boxes[@selected], @selected
        emit Crysterm::Event::ItemCancelled, @item_boxes[@selected], @selected
      end
    end
  end
end
