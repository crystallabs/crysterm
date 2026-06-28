module Crysterm
  module Mixin
    # The "list of selectable items" concern, extracted from `Widget::List` so
    # the item model can be shared without inheritance.
    #
    # Qt makes `QListWidget`, `QTreeWidget`, and `QTableView` *siblings* under
    # `QAbstractItemView`, while `QMenu` is a plain `QWidget`. Crysterm mirrors
    # that: `List`/`Tree`/`ListTable`/`ComboBox::Popup`/`FileManager` derive
    # `AbstractItemView` and `include` this module, and `Menu` — a `Box`, *not* an
    # item view — includes it standalone to reuse the row machinery. (It is
    # deliberately *not* mixed into `AbstractItemView`, so `Menu` can include it
    # without becoming one.) `List` itself stays a usable concrete widget that
    # also includes it, exactly as `Input` includes `Mixin::Interactive`.
    #
    # The `@_is_list` flag plus `#item_selected?` (overridden here) are the
    # duck-typed hooks the renderer keys off — see `Widget#item_selected?` and
    # `widget_rendering.cr` — so no `is_a?(List)` check is needed.
    module ItemView
      property ignore_keys = true
      property scrollable = true
      # Auto-show the scroll bar when items overflow (Qt `AsNeeded`); the bar's
      # thumb sizes from the item-count model via `#get_scroll_height`.
      # Inherited by `Tree`.
      @scrollbar_policy = Widget::ScrollBarPolicy::AsNeeded

      property _list_initialized = false

      property ritems = [] of String
      property selected = 0

      # When true, a single mouse click on an item activates it (rather than the
      # default two-click select-then-activate). Set by `Widget::Menu`.
      property? activate_on_click : Bool = false

      # When true, moving the pointer over a row selects it (no click required),
      # the way desktop menus track the mouse. Off for plain lists; set by
      # `Widget::Menu`. The per-row hook is `#hover_item`.
      property? hover_select : Bool = false

      # Whether more than one item can be selected at once, like Qt's
      # `QAbstractItemView::MultiSelection`. When on, Space toggles the current
      # item's membership in `#selected_indices` (the cursor still moves with the
      # arrow keys). When off, the list behaves as a single-selection list and
      # only the cursor item is highlighted.
      property? multi_select : Bool = false

      # Indices of the items that are part of the multi-selection (only
      # meaningful when `#multi_select?`). Maintained across insert/remove so the
      # marked items track their rows.
      getter selected_indices = Set(Int32).new

      # Tag-stripped text of the currently selected item (`""` when the list is
      # empty). Kept in sync by `#selekt`; useful e.g. for `Widget::Form`
      # value collection.
      getter value : String = ""

      # Lazily-built map of `clean_tags(item) => first index`, used by the
      # `get_item_index(String)` fallback so it doesn't re-run `clean_tags`
      # (a full gsub per item) on every lookup. Invalidated to `nil` whenever
      # `@ritems` is mutated; see `invalidate_item_index`.
      @clean_tags_index : Hash(String, Int32)? = nil

      @_is_list = true
      @interactive = true

      # React to mouse: click an item to select it (click the selected one to
      # activate it), and scroll the selection with the wheel. Items are wired
      # for this in `#create_item` when enabled.
      property? mouse = true

      def initialize(input = true, mouse = true, multi_select = false, items : Enumerable(String)? = nil, **box)
        @mouse = mouse
        @multi_select = multi_select
        super **box, input: input, keys: true

        @value = ""

        items.try &.each { |item| append_item item }

        selekt 0

        if @keys
          on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
        end

        on ::Crysterm::Event::Resize, ->on_resize(::Crysterm::Event::Resize)
      end

      # Returns the `::Crysterm::Style` an item box should render with, given whether it is
      # the selected item.
      #
      # The list draws its *own* border (and background) around the whole
      # widget, so an individual item must never carry a border of its own.
      # The non-selected branch of `::Crysterm::Style#item` falls back to the list's own
      # style (`@item || self`), which — when the list has a border — would make
      # every non-selected item draw a nested border, showing up as stray
      # line-drawing characters. We therefore strip the border from the item
      # style here. The selected branch (`styles.selected`) is already a
      # separate, border-less style, but is run through the same guard for
      # symmetry (and in case a user gives the selected style a border). See
      # `Widget#_render`, which calls this.
      def item_render_style(selected : Bool) : ::Crysterm::Style
        return without_border(style.item) unless selected
        selection_fallback without_border(styles.selected)
      end

      # Whether the selection state carries its own visible distinction (a color
      # or reverse video). When it does not — the unstyled floor, where
      # `styles.selected` lazily falls back to `normal` with no selection colors
      # — selection is shown via reverse-video instead (see `#selection_fallback`):
      # the one highlight that needs no color and reads on any terminal
      # background. This path is only reached for non-CSS-styled items (see
      # `#render_style_for`), so a themed selection (which sets explicit colors
      # via `Box:selected`) is never touched.
      private def selection_visibly_styled? : Bool
        return false unless styles.own_selected?
        sel = styles.selected
        sel.specified?(:fg) || sel.specified?(:bg) || sel.reverse?
      end

      # Returns *st* with reverse-video forced on when the selection has no
      # visible styling of its own, so the cursor row stays distinguishable with
      # no theme active. A `#dup` is taken before toggling so a shared
      # `styles.selected`/`normal` is never mutated in place. When the selection
      # is already visibly styled, *st* is returned untouched.
      private def selection_fallback(st : ::Crysterm::Style) : ::Crysterm::Style
        return st if selection_visibly_styled?
        st = st.dup
        st.reverse = true
        st
      end

      # Returns *base* with any border stripped: *base* untouched when it has no
      # border (the common case — no allocation), else a borderless `#dup`. Items
      # must never carry the list's border — the list draws the frame around the
      # whole widget, so a per-item border would nest stray line-drawing chars and
      # also reserve `iwidth`, shrinking the item's content area. Shared by the
      # item-style paths here and in `ListTable`/`Menu` (which subclass `List`).
      protected def without_border(base : ::Crysterm::Style) : ::Crysterm::Style
        return base unless base.border.any?
        borderless = base.dup
        borderless.border = false
        borderless
      end

      # Resolves the `::Crysterm::Style` an item box should render with. This is the single
      # entry point called from `Widget#_render`; subclasses (e.g.
      # `Widget::ListTable`, for alternating rows) override it.
      #
      # The cursor item gets the full `selected` highlight. In `#multi_select?`
      # mode the *other* checked items are underlined so they read as selected
      # without being confused with the cursor (Qt shows the current item and the
      # selected set distinctly).
      def render_style_for(item : Widget) : ::Crysterm::Style
        # If CSS styled this item (e.g. `List Box`, `Item:nth-child(even)`), use
        # the item's own cascade-computed style, reflecting selection through its
        # widget state so `:selected` rules apply.
        if item.css_styled?
          # In multi-select the cursor item gets the full `:selected` highlight,
          # while the *other* checked items stay in the normal state but are
          # underlined — so they read as selected without being confused with the
          # cursor (same distinction as the non-CSS path below).
          if multi_select?
            i = @items.index item
            item.state = (i == @selected) ? WidgetState::Selected : WidgetState::Normal
            style = item.style
            if i == @selected
              style = selection_overlay(style)
            elsif i && @selected_indices.includes?(i)
              style = style.dup
              style.underline = true
            end
            return style
          end

          selected = item_selected?(item)
          item.state = selected ? WidgetState::Selected : WidgetState::Normal
          base = item.style
          return selected ? selection_overlay(base) : base
        end

        # Fast path (the overwhelmingly common case): no multi-selection, so the
        # only "selected" item is the cursor — an O(1) array compare, no scan.
        unless multi_select?
          return item_render_style(@items[@selected]? == item)
        end

        i = @items.index item
        return item_render_style(true) if i == @selected

        if i && @selected_indices.includes?(i)
          marked = item_render_style(false).dup
          marked.underline = true
          return marked
        end

        item_render_style false
      end

      # Overlays the list-level selected style's colors onto a selected item's
      # CSS-computed *style* (from `selection-color`/`selection-background-color`,
      # or a `List:selected` rule / code). On the per-item CSS render path the
      # item box's own computed style is returned verbatim, so without this the
      # list-level selection colors — which live on the list's `styles.selected`,
      # not the item's — would never reach the screen. A no-op (returns *style*
      # unchanged) unless a distinct selected style was actually set.
      private def selection_overlay(style : ::Crysterm::Style) : ::Crysterm::Style
        return style unless styles.own_selected?
        overlay_colors style, styles.selected
      end

      # Returns *base* with *source*'s explicitly-set fg/bg laid over it: *base*
      # itself when *source* specifies neither color (the common case), else a
      # `#dup` carrying the overlaid colors. Used to bridge list-level
      # `selection-*`/`alternate-background-color` onto per-item CSS styles
      # without disturbing the item's other (non-color) properties.
      private def overlay_colors(base : ::Crysterm::Style, source : ::Crysterm::Style) : ::Crysterm::Style
        fg = source.specified?(:fg)
        bg = source.specified?(:bg)
        return base unless fg || bg
        out = base.dup
        out.fg = source.fg if fg
        out.bg = source.bg if bg
        out
      end

      # Whether *item* should render in the selected style: it is the cursor
      # item, or (in `#multi_select?` mode) it is part of `#selected_indices`.
      def item_selected?(item : Widget) : Bool
        # Fast path: single-selection lists only need an O(1) compare against the
        # cursor item (this runs once per item per frame from `Widget#_render`).
        return @items[@selected]? == item unless multi_select?

        i = @items.index item
        return false unless i
        i == @selected || @selected_indices.includes?(i)
      end

      # Tag-stripped text of every multi-selected item, in row order. In
      # single-selection mode this is just `[value]` (or `[]` when empty).
      def selected_values : Array(String)
        unless multi_select?
          # An empty list has no selection, so report none — `[]`, not `[""]`.
          # `@value` is correctly `""` here, but wrapping it would surface a
          # phantom one-element selection to callers (e.g. value collection),
          # contradicting both this method's documented contract and the
          # multi-select branch below, which yields `[]` for an empty selection.
          return [] of String if @items.empty?
          return [@value]
        end
        @selected_indices.to_a.sort.compact_map { |i| @ritems[i]?.try { |r| clean_tags r } }
      end

      # Adds *index* to the multi-selection (no-op unless `#multi_select?`).
      def select_item(index : Int)
        return unless multi_select?
        return unless 0 <= index < @items.size
        if @selected_indices.add?(index)
          emit ::Crysterm::Event::SelectItem, @items[index], index
        end
      end

      # Removes *index* from the multi-selection.
      def deselect_item(index : Int)
        @selected_indices.delete index
      end

      # Flips *index*'s membership in the multi-selection.
      def toggle_selection(index : Int)
        return unless multi_select?
        @selected_indices.includes?(index) ? deselect_item(index) : select_item(index)
      end

      # Clears the whole multi-selection.
      def clear_selection
        @selected_indices.clear
      end

      # A `List` has a fixed viewport that scrolls its items, so "scrollable right
      # now" must be a real content-vs-height overflow test — not the `@resizable`
      # always-scrollable short-circuit it would otherwise inherit (`really_scrollable?`
      # returns `@scrollable` for resizable widgets, which made an `AsNeeded`
      # vertical scroll bar — its `█` thumb — appear even when every item fits).
      # Mirrors `PlainTextEdit#really_scrollable?`.
      def really_scrollable?
        content_overflows_height?
      end

      # Keeps every item's right-edge reservation in lock-step with the vertical
      # scroll bar's *current* presence, each frame. The items *are* this widget's
      # content, so their reservation is exactly `#content_margin_x` (the same
      # columns the wrap/content-width math reserves — never a hardcoded `1`).
      # Items bake `right` at creation (`#create_item`), but whether the bar shows
      # can change after they exist — the list grew past the viewport, `#set_items`
      # replaced the data reusing the old item widgets (which never re-run
      # `create_item`), the viewport was resized, etc. A stale `right: 0` would let
      # the shown bar overpaint the last content column (visible with centered/
      # right-aligned rows, e.g. a `ListTable`); a stale reservation would waste a
      # column the bar no longer needs (the `Paris → Pari` over-reservation).
      # `right=` is a no-op when unchanged, so this costs nothing in steady state.
      # Items created resizable carry `right: nil` (full width) and are left alone.
      def render(with_children = true)
        # Only scrollable lists can reserve a bar column; for a plain list/menu
        # `content_margin_x` is always 0 and every item already has `right: 0`, so
        # skip the per-frame item walk entirely (the common non-scrolling case).
        if scrollable?
          reserve = content_margin_x
          @items.each { |item| item.right = reserve unless item.right.nil? }
        end
        super
      end

      # *right* defaults to `#content_margin_x` (the vertical bar's real width,
      # reserved only when it shows) — just the item's *initial* value; `#render`
      # re-syncs it every frame (see there). The horizontal bar reserves a bottom
      # *row* via `#hscrollbar_rows`, so nothing is taken off the right for it.
      def create_item(content, screen = ::Crysterm::Screen.global, align : ::Tput::AlignFlag | Shorthands = @align, top = 0, left = 0, right = content_margin_x, parse_tags = @parse_tags, height = 1, focus_on_click = false, normal_resizable = false, width = nil, alpha = style.alpha) # XXX hover_effects, focus_effects

        if @resizable || normal_resizable
          right = nil
        end

        # Items must not carry the list's border in their *layout* either: the
        # list draws the border around the whole widget, and `#item_render_style`
        # already strips it for drawing — but a border left on the item's own
        # style still reserves `iwidth` (one cell each side), shrinking the
        # content area (e.g. a tight popup menu showing "Abo" instead of "About").
        # Give items a borderless base style so their geometry matches.
        item_style = style
        item_style = without_border item_style if item_style.border.any?
        # An item's own style must not carry the list's *hidden* state: the
        # parent's visibility gates the subtree, so a style captured while the
        # list is hidden would otherwise keep `visible: false` and never reappear
        # when the list is shown. This bites whenever rows are built from a hidden
        # list — menu rows added after `hide`, or (now that menus are theme-driven
        # rather than given an inline `Style.new(border: true)`) a freshly opened
        # menu whose inline style has no border, so `without_border` above didn't
        # already dup it. Dup if we're still pointing at the list's own style — so
        # forcing this never flips the list itself visible — then mark it visible.
        item_style = item_style.dup if item_style.same?(style)
        item_style.visible = true

        item = Widget::Box.new(content: content, screen: screen, align: align, top: top, left: left, right: right, parse_tags: parse_tags, height: 1, focus_on_click: focus_on_click, width: width, style: item_style)
        # XXX above: alpha

        if mouse?
          # By default a click selects the item and clicking the already-selected
          # one activates it (Blessed-style two-click). With `#activate_on_click?`
          # (used by menus) a single click both selects and activates.
          item.on(::Crysterm::Event::Click) do
            if i = @items.index item
              focus
              if activate_on_click? || i == @selected
                enter_selected i
              else
                selekt i
              end
              request_render
            end
          end

          # Wheel moves the selection (and `#accept`s the event so the screen's
          # default "scroll the view" behavior doesn't also fire).
          item.on(::Crysterm::Event::Mouse) do |e|
            if e.action.wheel_up?
              move -2
              e.accept
              request_render
            elsif e.action.wheel_down?
              move 2
              e.accept
              request_render
            end
          end

          # With `#hover_select?` (menus), merely moving the pointer onto a row
          # highlights it — no click needed — via the overridable `#hover_item`.
          if hover_select?
            item.on(::Crysterm::Event::MouseOver) do
              if i = @items.index item
                hover_item i
                request_render
              end
            end
          end
        end

        emit Crysterm::Event::CreateItem

        item
      end

      def append_item(content : String)
        item = create_item content
        item.top = @items.size

        @ritems.push content
        invalidate_item_index
        @items.push item
        append item

        if @items.size == 1
          selekt 0
        end

        emit ::Crysterm::Event::AddItem

        item
      end

      def append_item(widget : Widget)
        append_item widget.get_content
      end

      def remove_item(child : Widget)
        i = get_item_index child
        return unless i >= 0

        if item = @items[i]?
          child = @items.delete_at i
          @ritems.delete_at i
          invalidate_item_index
          remove child
        end

        (i...@items.size).each { |j| @items[j].top = @items[j].top.as(Int) - 1 }

        # Keep the multi-selection aligned with the shifted rows: drop the removed
        # index and slide everything past it down by one.
        if @selected_indices.includes?(i) || @selected_indices.any? { |s| s > i }
          @selected_indices = @selected_indices.compact_map do |s|
            next nil if s == i
            s > i ? s - 1 : s
          end.to_set
        end

        # Keep the single-selection cursor on the same logical item. Removing a
        # row *before* the cursor shifts every later row (including the selected
        # one) down by one, so the cursor must slide down with it — exactly as
        # the multi-selection indices are slid above. Without this `@selected`
        # stayed put and silently jumped to the next item, or — when the
        # selection was the last row — pointed past the end at a phantom row (so
        # nothing rendered as selected and `@value` went stale). Removing the
        # selected row itself keeps the original behavior (select the row before).
        if i < selected
          selekt selected - 1
        elsif i == selected
          # The selected row itself was removed: the cursor lands on the prior
          # row (`i - 1`), or — when the removed row was the first (`i == 0`) —
          # stays at index 0, which now holds what used to be the *next* row.
          # That latter case keeps the same `@selected` value (0), so `#selekt`'s
          # unchanged-index short-circuit (`@selected == index &&
          # @_list_initialized`) would return *without* refreshing `@value` or
          # emitting `SelectItem`, leaving `value` pointing at the removed row's
          # text. Clear the latch so the selection logic re-runs in full for the
          # now-different item under the cursor. (For `i > 0` the index actually
          # changes, so this is a harmless no-op there.)
          @_list_initialized = false
          selekt i - 1
        end

        emit ::Crysterm::Event::RemoveItem

        item
      end

      def get_item(child : Widget)
        i = get_item_index child
        return nil unless i >= 0
        @items[i]?
      end

      def get_item_index(child : Int)
        child
      end

      def get_item_index(child : String)
        # Exact (raw, tags-included) match takes priority, matching the
        # previous behavior.
        i = @ritems.index child
        return i if i

        # Fallback: match against the tag-stripped form of each item. The
        # cleaned->index map is built once and reused until `@ritems` changes,
        # instead of re-cleaning every item on each call. First index wins, as
        # the previous linear scan did.
        index = @clean_tags_index ||= begin
          h = {} of String => Int32
          @ritems.each_with_index do |item, idx|
            cleaned = clean_tags item
            h[cleaned] = idx unless h.has_key? cleaned
          end
          h
        end
        index[child]? || -1
      end

      # Drops the cached `clean_tags` index. Called from every method that
      # mutates `@ritems` so the lazily-rebuilt map can never go stale.
      private def invalidate_item_index
        @clean_tags_index = nil
      end

      # Accepts any `Widget` (not only `Widget::Box`) so that callers holding
      # a `child : Widget` resolve here. Returns -1 when not found, matching
      # the `Int`/`String` overloads and the `>= 0` checks in callers.
      def get_item_index(child : Widget)
        (@items.index child) || -1
      end

      def selekt(index : Int)
        return unless interactive?

        if @items.empty?
          @selected = 0
          @value = ""
          # The selection is back to its uninitialized state: clear the
          # `@_list_initialized` latch so that re-populating the list actually
          # re-runs the body below. Without this, emptying a list (the last
          # `remove_item`/a `set_items []`) leaves `@selected == 0` AND
          # `@_list_initialized == true`, so the `selekt 0` that `append_item`
          # fires for the first new row hits the unchanged-index short-circuit
          # and returns *without* refreshing `@value` or emitting `SelectItem` —
          # the new row renders as selected while `value` stays the empty string
          # (stale `Form` value collection, no `SelectItem` listener fired).
          @_list_initialized = false
          scroll_to 0
          return
        end

        # XXX change this to more thread & bug safe code.

        index = index.clamp(0, @items.size - 1)

        return if @selected == index && @_list_initialized
        @_list_initialized = true

        @selected = index
        @value = clean_tags @ritems[@selected]

        # Gate the scroll + `SelectItem` emit on having been laid out, not on
        # having a `#parent`. A top-level widget appended straight to a `Screen`
        # has no `#parent` (a `Screen` is not a `Widget`; `Screen#insert` sets
        # `screen=`, not `parent=`), so the old `unless @parent` guard silently
        # skipped `scroll_to`/`SelectItem` for every screen-level list — the
        # list would never scroll to keep the selection visible, nor notify
        # listeners. `@lpos` is nil only until the first render (when scrolling
        # can't be computed anyway), and set thereafter for parented and
        # top-level widgets alike.
        return unless @lpos

        scroll_to @selected

        emit ::Crysterm::Event::SelectItem, @items[@selected], @selected
      end

      def selekt(widget : Widget)
        if i = @items.index(widget)
          selekt i
        end
      end

      # Hook invoked when the pointer moves onto row *i* and `#hover_select?` is
      # on. The default just moves the selection there; `Widget::Menu` overrides
      # it to also open/close submenus.
      def hover_item(i : Int)
        selekt i
      end

      def clear_items
        set_items [] of String
      end

      def push_item(content)
        append_item content
        @items.size
      end

      def pop_item
        return if @items.empty?
        # `remove_item` only accepts a `Widget`; pass the last item itself
        # rather than an `Int` index (which matches no overload).
        remove_item @items[-1]
      end

      def unshift_item(content)
        insert_item 0, content
        @items.size
      end

      def shift_item
        return if @items.empty?
        remove_item @items[0]
      end

      def move(offset)
        selekt selected + offset
      end

      def up(offset = 1)
        move -offset
      end

      def down(offset = 1)
        move offset
      end

      def insert_item(child, content : String)
        i = get_item_index child
        return unless i >= 0
        if i >= @items.size
          return append_item content
        end
        item = create_item content
        (i...@items.size).each { |j| @items[j].top = @items[j].top.as(Int) + 1 }
        # Slide multi-selected indices at/after the insertion point up by one.
        if @selected_indices.any? { |s| s >= i }
          @selected_indices = @selected_indices.map { |s| s >= i ? s + 1 : s }.to_set
        end
        item.top = i
        @ritems.insert i, content
        invalidate_item_index
        @items.insert i, item
        append item
        # Keep the single-selection cursor on the same logical item. Inserting a
        # row at or before the cursor shifts every row from the cursor onward
        # (including the selected one) down by one, so the cursor must slide down
        # with them — exactly as the multi-selection indices are slid above
        # (`s >= i`), and the mirror of the realignment `remove_item` performs.
        # The old `i == selected` guard only caught an insert *at* the cursor; an
        # insert *before* it (`i < selected`) left `@selected` pointing at a
        # different item, with `@value` going stale.
        if i <= selected
          selekt selected + 1
        end
        emit Crysterm::Event::InsertItem
      end

      def set_item(child, content : String)
        # TODO In these places where index is received, make it receive both index and element,
        # so that we don't modify the wrong element later.
        i = get_item_index child
        return unless i >= 0

        @items[i]?.try &.set_content(content)
        if i < @ritems.size
          @ritems[i] = content
          invalidate_item_index
          # Keep the cached selection `#value` in sync when the *selected* row's
          # text is changed. `@value` is otherwise only refreshed by `#selekt`,
          # which early-returns on an unchanged index — so editing the current
          # item's content in place (e.g. `Pine`'s status row, or a `ListTable`
          # re-formatting its selected row) left `value` stale, and any consumer
          # of it (`Form` value collection, etc.) saw the previous text.
          @value = clean_tags(content) if i == @selected
        end
      end

      def set_item(child, widget : Widget)
        set_item child, content: widget.get_content
      end

      def set_items(items)
        # The row set is being replaced wholesale; stale indices can't be
        # meaningfully carried over, so drop the multi-selection.
        @selected_indices.clear
        original = @items.dup
        selekted = selected
        sel = @ritems[selekted]?

        selekt 0

        items.each_with_index do |item, i|
          if itm = @items[i]?
            itm.set_content item
          else
            append_item item
          end
        end

        # Remove only the *leftover* original items (those past the end of the
        # new list). The first `items.size` originals were reused above via
        # `set_content`, so removing them too (as the old `original.each` did)
        # detached the very widgets we just repopulated. Also use `remove_item`,
        # not `remove`: `remove` only unlinks the widget from the children tree
        # and leaves `@items`/`@ritems` holding stale entries, desyncing them.
        if original.size > items.size
          original[items.size..].each do |itm|
            remove_item itm
          end
        end

        @ritems = items
        invalidate_item_index

        # Try to find our old item if it still exists
        if sel
          sel = items.index sel
          if sel
            selekt sel
          elsif @items.size == original.size
            # Use the saved selection (`selekted`); `selected` was just reset to
            # 0 by `selekt 0` above.
            selekt selekted
          else
            selekt Math.min selekted, @items.size - 1
          end
        end

        # Rows were reused in place (`set_content`) above, so the selection may
        # land on the *same* index whose text just changed — in which case
        # `selekt`'s unchanged-index short-circuit (`@selected == index &&
        # @_list_initialized`) never refreshed the cached `#value`, leaving it on
        # the pre-replacement text. Sync it to the now-current row (tags stripped,
        # like `#selekt`/`#set_item`) so `Form` value collection and other `value`
        # consumers don't read stale content. `""` when the list ended up empty.
        @value = @ritems[@selected]?.try { |r| clean_tags r } || ""

        emit Crysterm::Event::SetItems
      end

      def enter_selected(i)
        selekt i
        enter_selected
      end

      def enter_selected
        # Nothing to act on when the list is empty. The events carry a non-nil
        # `Widget::Box`, and `items[selected]` would raise `IndexError` on an
        # empty list (`selected == 0`, no rows) — a focused empty list pressing
        # Enter routes straight here from `#on_keypress`. (Blessed's JS yields a
        # benign `undefined` here; Crystal's strict indexing turns it into a
        # crash, so we guard instead.)
        return if @items.empty?
        emit Crysterm::Event::ActionItem, items[selected], selected
        emit Crysterm::Event::SelectItem, items[selected], selected
      end

      def cancel_selected(i)
        selekt i
        cancel_selected
      end

      def cancel_selected
        # See `#enter_selected`: guard the empty list so Escape on a focused
        # empty list does not raise `IndexError` on `items[selected]`.
        return if @items.empty?
        emit Crysterm::Event::ActionItem, items[selected], selected
        emit Crysterm::Event::CancelItem, items[selected], selected
      end

      # Enables the incremental-search prompt (`/` forward, `?` backward) in the
      # key handler.
      property? search = true

      # Lazily-created one-line input shown at the bottom of the screen during a
      # search (see `#start_search`).
      @search_box : Widget::LineEdit? = nil

      # Index of the first item whose tag-stripped, case-insensitive text
      # contains *query*, scanning from the current selection and wrapping.
      # Returns the current selection when nothing matches. *back* searches
      # upward.
      def fuzzy_find(query : String, back = false) : Int32
        return selected if @items.empty?
        q = query.downcase
        n = @items.size
        step = back ? -1 : 1
        i = selected
        n.times do
          i = (i + step) % n
          i += n if i < 0
          return i if clean_tags(@ritems[i]).downcase.includes? q
        end
        selected
      end

      private def ensure_search_box : Widget::LineEdit
        @search_box ||= begin
          box = Widget::LineEdit.new(
            screen: screen,
            bottom: 0, left: 0, right: 0, height: 1,
          )
          box.add_css_class "search" # themed via `.search { ... }`
          screen.append box
          box.hide
          box
        end
      end

      # Opens the incremental-search prompt. Typing a query and pressing Enter
      # jumps to the next matching item; Escape cancels. *back* searches upward.
      def start_search(back = false)
        return unless search?
        return if @items.empty?

        sb = ensure_search_box
        sb.set_label(back ? "?" : "/")
        sb.value = ""
        sb.show
        request_render

        sb.read_input do |_err, data|
          sb.hide
          focus
          if data && !data.empty?
            selekt fuzzy_find(data, back)
          end
          request_render
        end
      end

      # TODO
      # pick

      def on_keypress(e)
        visible = aheight - iheight - hscrollbar_rows
        half = Math.max visible // 2, 1

        case
        when e.key == ::Tput::Key::Up, (@vi && e.char == 'k')
          up
        when e.key == ::Tput::Key::Down, (@vi && e.char == 'j')
          down
        when e.key == ::Tput::Key::Home, (@vi && e.char == 'g')
          selekt 0
        when e.key == ::Tput::Key::End, (@vi && e.char == 'G')
          selekt @items.size - 1
        when e.key == ::Tput::Key::CtrlU
          move -half
        when e.key == ::Tput::Key::CtrlD
          move half
        when e.key == ::Tput::Key::PageUp, e.key == ::Tput::Key::CtrlB
          move -visible
        when e.key == ::Tput::Key::PageDown, e.key == ::Tput::Key::CtrlF
          move visible
        when @vi && e.char == 'H'
          selekt @child_base
        when @vi && e.char == 'M'
          selekt @child_base + visible // 2
        when @vi && e.char == 'L'
          selekt @child_base + visible - 1
        when search? && e.char == '/'
          start_search false
        when search? && e.char == '?'
          start_search true
        when multi_select? && e.char == ' '
          toggle_selection selected
        when e.key == ::Tput::Key::Enter
          enter_selected
        when e.key == ::Tput::Key::Escape
          cancel_selected
        else
          return
        end

        # A key we handled: consume it (so it doesn't also drive an ancestor,
        # e.g. a `Form`'s own vi `j`/`k`) and repaint.
        e.accept
        request_render
      end

      def on_resize(e)
        visible = aheight - iheight - hscrollbar_rows
        if visible >= selected + 1
          @child_base = 0
          @child_offset = selected
        else
          # NOTE Is this supposed to be: child_base = visible - selected + 1
          @child_base = selected - visible + 1
          @child_offset = visible - 1
        end
      end
    end
  end
end
