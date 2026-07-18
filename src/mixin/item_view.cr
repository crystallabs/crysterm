require "./nav_keys"

module Crysterm
  module Mixin
    # The "list of selectable items" concern (Qt's `QAbstractItemView`): the text
    # rows, the selection model, the current index, and the keys/mouse that move
    # them. Shared by the item-view widgets without inheritance, so a widget that
    # must root in a different base can include it standalone.
    #
    # The including type supplies a scrollable `Box`-like host: `@items` (the
    # backing item boxes) and `@ritems` (their raw text) in lock-step, plus
    # `clean_tags`, `visible_content_rows`, `scroll_to`, `@child_base`/
    # `@child_offset` and `styles`.
    #
    # The `@_is_list` flag plus `#item_selected?` are the duck-typed hooks the
    # renderer keys off, so no `is_a?(List)` check is needed.
    module ItemView
      include NavKeys
      # For the `#<<`/`#>>` operator aliases below. Included again here because a
      # standalone module doesn't inherit macros from its future includers.
      include Crystallabs::Helpers::Alias_Methods

      # How a mouse-wheel notch is interpreted (see `#wheel_scroll`).
      enum WheelMode
        # Wheel behaves like the arrow keys: it moves the selection, scrolling
        # only to keep it visible (plain `List`/`Tree`/`Menu`).
        MoveSelection
        # Wheel scrolls the *viewport* under a stationary pointer; the selection
        # tracks the entry under the cursor (`#hover_select?` drop-downs), so the
        # wheel and hover-select don't fight over the selection.
        ScrollViewUnderPointer
      end

      property wheel_mode : WheelMode = WheelMode::MoveSelection

      # How many items the user may select at once (Qt's
      # `QAbstractItemView::selectionMode`).
      #
      # Qt's `ExtendedSelection`/`ContiguousSelection` are deliberately absent:
      # nothing here implements them, and an enum member that silently behaved
      # like `MultiSelection` would be worse than not offering it.
      enum SelectionMode
        # Items cannot be selected; the view is display-only. The cursor never
        # moves and `#current_index=` is a no-op. `#interactive?` is a separate
        # focus-level gate — both must pass.
        NoSelection
        # Exactly one item is current at a time (the default).
        SingleSelection
        # Space toggles an item's membership in `#selected_indices` on top of the
        # single current item, which keeps moving with the arrow keys.
        MultiSelection
      end

      # Auto-show the scroll bar when items overflow (Qt `AsNeeded`); thumb size
      # comes from `#scroll_height`.
      @scrollbar_policy = Widget::ScrollBarPolicy::AsNeeded

      # Latched true by the first `#current_index=`; internal state, no accessor.
      @_list_initialized = false

      @ritems = [] of String

      # Tag-carrying raw item texts, parallel to `#items`. Read-only view; the
      # list rebuilds it internally as items are added/removed/set.
      def item_texts : Array(String)
        @ritems
      end

      # Backing store for `#current_index`.
      @selected = 0

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

        if @items.empty?
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
        # `@items.size == @ritems.size` invariant every mutator maintains.
        index = index.clamp(0, @items.size - 1)

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

        emit ::Crysterm::Event::ItemSelected, @items[@selected], @selected
      end

      # Number of items in the view (Qt's `QListWidget#count`). Answered across the
      # item-view family, so callers never have to know which internal array
      # (`items`/`ritems`/`roots`/`actions`) a given widget happens to keep.
      def count : Int32
        @items.size
      end

      # Blank rows of vertical spacing inserted *between* items (Qt's
      # `QListView` spacing). Gaps aren't items — nothing to click/select there.
      # `0` (default) stacks items flush.
      getter item_spacing : Int32 = 0

      # Re-places existing items when the spacing changes at runtime.
      def item_spacing=(value : Int32) : Int32
        @item_spacing = value
        @items.each_with_index { |it, i| it.top = item_row(i) }
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
      # mapped back to an item *index* (vi H/M/L, wheel scroll, hover clamp):
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
        return base if @item_spacing.zero? || @items.empty?
        Math.max(base, item_row(@items.size - 1) + 1)
      end

      # Total content height in rows, including inter-item gaps, so scrollbar/
      # overflow logic sees the real extent (`scroll_extent_bottom` otherwise counts
      # items, ignoring spacing). Unchanged when not spaced.
      def scroll_height : Int32
        spaced_extent super
      end

      # Spaced extent for the scroll clamp/thumb. The base `scroll_extent_bottom`
      # returns `@items.size` for lists, ignoring `item_spacing`, which reins
      # `clamp_child_base_to_content` in too far and hides the last item(s) of a
      # spaced, overflowing list; report the same spaced height as
      # `#scroll_height` so the clamp reaches the true bottom.
      protected def scroll_extent_bottom
        spaced_extent super
      end

      # When true, a single mouse click on an item activates it (rather than the
      # default two-click select-then-activate).
      property? activate_on_click : Bool = false

      # When true, moving the pointer over a row selects it (no click required),
      # like desktop menus. Off for plain lists. Per-row hook is `#hover_item`.
      property? hover_select : Bool = false

      # How many items may be selected at once (Qt's
      # `QAbstractItemView#selectionMode`). See `SelectionMode`.
      property selection_mode : SelectionMode = SelectionMode::SingleSelection

      # Whether the view is in `SelectionMode::MultiSelection`. A derived query,
      # not a stored flag — assign `#selection_mode` to change it.
      def multi_select? : Bool
        @selection_mode.multi_selection?
      end

      # Indices in the multi-selection (only meaningful when `#multi_select?`).
      # Maintained across insert/remove so marked items track their rows.
      getter selected_indices = Set(Int32).new

      # Row indices that behave as non-selectable dividers: the selection cursor
      # steps *over* them (arrow/paging keys land on the nearest real row beyond)
      # and a click or Enter on one does nothing. Empty by default, so the skip
      # logic is a no-op until a host marks rows. Set it *after* `#items=`: a
      # wholesale replace does not clear it, since row *meaning* is the host's.
      @nonselectable = Set(Int32).new

      # :ditto:
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
        Mixin::ActionBar.nearest_selectable(@items.size, index, dir) { |i| @nonselectable.includes? i }
      end

      @value : String = ""

      # Tag-stripped text of the currently selected item (`""` when empty),
      # Qt's `currentText`. Kept in sync by `#current_index=`.
      def current_text : String
        @value
      end

      # Lazily-built map of `clean_tags(item) => first index`, used by the
      # `#index_of(String)` fallback to avoid re-running `clean_tags` (a full gsub
      # per item) on every lookup. Invalidated by `invalidate_item_index` whenever
      # `@ritems` is mutated.
      @clean_tags_index : Hash(String, Int32)? = nil

      # Lazily-built identity map `item widget => its index in @items`. The
      # `multi_select?` render path resolves an item's index once per child per
      # frame, which as `@items.index item` is a linear scan per item ⇒
      # O(n²)/frame. Keyed by reference identity (`Reference#hash`/`#==` are by
      # `object_id`), matching `Array#index`'s `==`. Invalidated by
      # `invalidate_item_index` whenever `@items` is mutated.
      @item_index : Hash(Widget, Int32)? = nil

      # Memo for `#selection_fallback`'s reverse-video copy, keyed by source style
      # identity. The cascade replaces the backing per-state style, so a `same?`
      # hit means the copy is still valid; only rebuilt on a new source object
      # instead of a `Style#dup` per call.
      @_sel_reverse_fallback_src : ::Crysterm::Style?
      @_sel_reverse_fallback_copy : ::Crysterm::Style?

      @_is_list = true
      @interactive = true

      # React to mouse: click an item to select it (click the selected one to
      # activate it), scroll the selection with the wheel. Wired up in
      # `#create_item`.
      property? mouse = true

      def initialize(*, input : Bool = true, mouse : Bool = true, selection_mode : SelectionMode = SelectionMode::SingleSelection, items : Enumerable(String)? = nil, **box)
        @mouse = mouse
        @selection_mode = selection_mode
        # `merge` lets an explicit caller `keys:` (in `**box`) override the
        # key-enabled default without tripping a duplicate-key error.
        super **{input: input, keys: true}.merge(box)

        # Assign the inherited base ivars (`Widget#ignore_keys?`,
        # `#scrollable?`) rather than redeclaring the properties, which would
        # shadow the base getters with a duplicate pair.
        @ignore_keys = true
        @scrollable = true

        @value = ""

        items.try &.each { |item| add_item item }

        self.current_index = 0

        if @keys
          on ::Crysterm::Event::KeyPress, ->on_keypress(::Crysterm::Event::KeyPress)
        end

        on ::Crysterm::Event::Resize, ->on_resize(::Crysterm::Event::Resize)
      end

      # Returns the `::Crysterm::Style` an item box should render with, given whether it is
      # the selected item.
      #
      # The list draws its own border around the whole widget, so individual items
      # must never carry one: the non-selected branch of `::Crysterm::Style#item`
      # falls back to the list's own style (`@item || self`), which would
      # otherwise make every item draw a nested border. The selected branch
      # (`styles.selected`) is already border-less but runs through the same guard
      # for symmetry.
      def item_render_style(selected : Bool) : ::Crysterm::Style
        return without_border(style.item) unless selected
        # Fuse the selected style's two transforms (strip border, force
        # reverse-video at the unstyled floor) into a single `#dup`.
        # `styles.selected` itself is never mutated in place, and nothing is
        # cached across frames.
        base = styles.selected
        strip = base.border.any?
        reverse = !selection_visibly_styled?
        return base unless strip || reverse
        out = base.dup
        out.border = false if strip
        out.reverse = true if reverse
        out
      end

      # Whether the selection state carries its own visible distinction (a color
      # or reverse video). When it does not — the unstyled floor, where
      # `styles.selected` falls back to `normal` with no selection colors —
      # selection falls back to reverse-video instead (see `#selection_fallback`),
      # which needs no color and reads on any terminal background. Only reached
      # for non-CSS-styled items; themed selections (`Box:selected`) are never
      # touched.
      private def selection_visibly_styled? : Bool
        return false unless styles.own_selected?
        styles.selected.visibly_styled?
      end

      # Returns *st* with reverse-video forced on when the selection has no
      # visible styling of its own, so the cursor row stays distinguishable with
      # no theme active. Returns *st* untouched when already visibly styled.
      #
      # The memo pair `@_sel_reverse_fallback_{src,copy}` is kept separate from
      # the focus-highlight fallback's, so a `List` can run both in one frame.
      private def selection_fallback(st : ::Crysterm::Style) : ::Crysterm::Style
        result, @_sel_reverse_fallback_src, @_sel_reverse_fallback_copy =
          reverse_fallback_memo st, selection_visibly_styled?, @_sel_reverse_fallback_src, @_sel_reverse_fallback_copy
        result
      end

      # Returns *base* with any border stripped: *base* untouched when borderless
      # (no allocation), else a borderless `#dup`. Items must never carry the
      # list's border — it would nest stray line-drawing chars and reserve
      # `ihorizontal`, shrinking the item's content area.
      protected def without_border(base : ::Crysterm::Style) : ::Crysterm::Style
        return base unless base.border.any?
        borderless = base.dup
        borderless.border = false
        borderless
      end

      # Resolves the `::Crysterm::Style` an item box should render with. Single
      # entry point called from `Widget#_render`; overridable (e.g. for
      # alternating rows).
      #
      # The cursor item gets the full `selected` highlight. In `#multi_select?`
      # mode the *other* checked items are underlined so they read as selected
      # without being confused with the cursor (Qt's distinct current-item vs.
      # selected-set display).
      def render_style_for(item : Widget) : ::Crysterm::Style
        # CSS-styled item (e.g. `List Box`, `Item:nth-child(even)`): use the
        # item's own cascade-computed style, reflecting selection through its
        # widget state so `:selected` rules apply.
        if item.css_styled?
          # Multi-select: cursor item gets the full `:selected` highlight, other
          # checked items stay normal but underlined.
          if multi_select?
            i = item_index_of item
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

        # Fast path: no multi-selection, so the only "selected" item is the
        # cursor — O(1) array compare, no scan.
        unless multi_select?
          return item_render_style(@items[@selected]? == item)
        end

        i = item_index_of item
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
      # or a `List:selected` rule). They live on `styles.selected`, not the item's
      # style, so without this they never reach the window. No-op unless a
      # distinct selected style was set.
      private def selection_overlay(style : ::Crysterm::Style) : ::Crysterm::Style
        return style unless styles.own_selected?
        overlay_colors style, styles.selected
      end

      # Returns *base* with *source*'s explicitly-set fg/bg laid over it: *base*
      # itself when neither color is specified, else a `#dup` carrying the
      # overlaid colors. Bridges list-level `selection-*`/`alternate-background-color`
      # onto per-item CSS styles without touching other properties.
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
        # Fast path: single-selection only needs an O(1) compare against the
        # cursor item (runs once per item per frame from `Widget#_render`).
        return @items[@selected]? == item unless multi_select?

        i = item_index_of item
        return false unless i
        i == @selected || @selected_indices.includes?(i)
      end

      # Tag-stripped text of every multi-selected item, in row order. In
      # single-selection mode this is just `[value]` (or `[]` when empty).
      def selected_values : Array(String)
        unless multi_select?
          # Empty list has no selection: report `[]`, not `[""]` (wrapping
          # `@value` would surface a phantom one-element selection).
          return [] of String if @items.empty?
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
        return unless 0 <= index < @items.size
        if @selected_indices.add?(index)
          emit ::Crysterm::Event::ItemSelected, @items[index], index
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

      # An item view has a fixed viewport, so "scrollable right now" must be a real
      # content-vs-height overflow test, not the `@shrink_to_fit`
      # always-scrollable short-circuit it would otherwise inherit — which shows
      # an `AsNeeded` scroll bar even when every item fits.
      def overflows_y?
        content_overflows_height?
      end

      # Minimum thumb (handle) length, in cells, for a list-like scroll bar.
      # Floors the otherwise purely proportional handle so it renders the same
      # whether the list has a dozen rows or a couple hundred, instead of decaying
      # to a lone 1-cell nub.
      ITEM_VIEW_MIN_THUMB = 3

      # Gives the bound vertical scroll bar the shared list-view minimum handle
      # length on top of the base setup. Idempotent, like the base.
      protected def ensure_scrollbar_widget : Widget::ScrollBar
        sb = super
        sb.min_thumb = ITEM_VIEW_MIN_THUMB
        sb
      end

      # Keeps every item's right-edge reservation in lock-step with the vertical
      # scroll bar's *current* presence, each frame. Items bake `right` at
      # creation, but whether the bar shows can change later (list grows past
      # viewport, `#items=` reuses old item widgets, resize). A stale `right: 0`
      # lets a shown bar overpaint the last content column; a stale reservation
      # wastes a column the bar no longer needs. `right=` is a no-op when
      # unchanged. Shrink-to-content items carry `right: nil` and are left alone.
      def render(with_children = true)
        # Only scrollable lists reserve a bar column; for a plain list/menu
        # `content_margin_x` is always 0, so skip the per-frame item walk.
        if scrollable?
          reserve = content_margin_x
          @items.each { |item| item.right = reserve unless item.right.nil? }
        end
        super
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
            if (i = @items.index item) && !@nonselectable.includes?(i)
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
              if i = @items.index item
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
      def add_item(content : String)
        item = create_item content
        item.top = item_row(@items.size)

        @ritems.push content
        invalidate_item_index
        @items.push item
        append item

        if @items.size == 1
          self.current_index = 0
        end

        emit ::Crysterm::Event::ItemAdded

        item
      end

      # :ditto:
      def add_item(widget : Widget)
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
      def <<(content : String)
        add_item content
        self
      end

      # Removes the item at *child* — a row index, an item's text, or the item
      # box itself — and returns its box (`nil` when *child* resolves to no item).
      # Row-based, like Qt's `QListWidget#takeItem`.
      def remove_item(child)
        i = index_of child
        return unless i

        item = @items[i]?
        if item
          @items.delete_at i
          @ritems.delete_at i
          invalidate_item_index
          remove item
        end

        (i...@items.size).each { |j| @items[j].top = item_row(j) }

        # Keep the multi-selection aligned: drop the removed index, slide
        # everything past it down by one.
        if @selected_indices.includes?(i) || @selected_indices.any? { |s| s > i }
          @selected_indices = @selected_indices.compact_map do |s|
            next nil if s == i
            s > i ? s - 1 : s
          end.to_set
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
        return nil unless i
        @items[i]?
      end

      # Index of *child* (a row index, an item's text, or the item box itself),
      # or `nil` when the view holds no such item — like `Array#index`.
      #
      # The `Int` form validates rather than handing its argument back, so an
      # out-of-range row (`set_item 999, "x"`) is caught here instead of
      # silently no-op'ing at the call site.
      def index_of(child : Int) : Int32?
        i = child.to_i
        (0 <= i < @items.size) ? i : nil
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

      # Drops the cached `clean_tags` index so it's rebuilt fresh next lookup.
      # Called from every method that mutates `@ritems`.
      private def invalidate_item_index
        @clean_tags_index = nil
        @item_index = nil
      end

      # O(1) index of item widget *item* in `@items` (nil when absent), via the
      # lazily-built `@item_index` map. Same result as `@items.index item`,
      # without the per-item linear scan on the hot render path.
      private def item_index_of(item : Widget) : Int32?
        index = @item_index ||= begin
          h = {} of Widget => Int32
          @items.each_with_index { |it, i| h[it] = i }
          h
        end
        index[item]?
      end

      # :ditto: — accepts any `Widget`, not only `Widget::Box`.
      def index_of(child : Widget) : Int32?
        @items.index child
      end

      # Hook invoked when the pointer moves onto item *i* and `#hover_select?` is
      # on. *i* is the item's absolute index — hit-testing runs against painted
      # geometry, so a scrolled list reports the real entry under the pointer, not
      # a viewport row — and selecting it directly is correct at any scroll
      # offset. The clamp to the visible window only guards the fringe where an
      # item box painted at the viewport's edge stays hit-testable one row past
      # the last fully-shown row, so a hover there parks on the last visible entry
      # instead of jumping to an off-screen one. Overridable (e.g. to open/close
      # submenus).
      def hover_item(i : Int)
        vis = visible_content_rows
        vis = 1 if vis < 1
        # Clamp to the visible *item* range: `@child_base`/`vis` are content rows,
        # so with `item_spacing > 0` a bare `clamp(@child_base, …)` would compare
        # an item index against row bounds and snap a legitimately-visible item to
        # a different one. Convert the row bounds to item indices first.
        self.current_index = i.clamp(item_at_row(@child_base), item_at_row(@child_base + vis - 1))
      end

      # Removes every item (Qt's `QListWidget#clear`).
      def clear
        self.items = [] of String
      end

      # Moves the selection by *delta* rows (negative = up), through
      # `#current_index=` so it clamps and steps over dividers.
      def move_selection(delta : Int32)
        self.current_index = @selected + delta
      end

      # Handles one mouse-wheel notch (*dir* is `-1` up / `+1` down). Branches on
      # `#wheel_mode`: `MoveSelection` (default) treats the wheel like the arrow
      # keys — two rows per notch, scrolling only to keep the selection visible;
      # `ScrollViewUnderPointer` scrolls the viewport under a stationary pointer
      # (drop-downs), keeping the selection on the entry under the cursor.
      def wheel_scroll(dir : Int32) : Nil
        if @wheel_mode.scroll_view_under_pointer?
          scroll_view_under_pointer dir
        else
          move_selection dir * 2
        end
      end

      # The `ScrollViewUnderPointer` body. Shifts the viewport one row
      # (`#child_base`) and re-selects whatever entry lands under the cursor —
      # i.e. the selection's current viewport row (`@child_offset`, which
      # `#hover_item` keeps pinned to the pointer). Wheel and hover-select must
      # agree on the single rule "selected == entry under the cursor", or the
      # wheel nudges the selection only for the next hover to snap it back. At the
      # top/bottom edges, where the view can no longer scroll, it steps the
      # selection within the visible page so the first/last entries stay reachable
      # by the wheel alone.
      private def scroll_view_under_pointer(dir : Int32) : Nil
        return if dir == 0 || @items.empty?
        step = dir > 0 ? 1 : -1
        visible = visible_content_rows
        visible = 1 if visible < 1
        # The scrollable extent is in content *rows* (`scroll_height` includes
        # the inter-item gaps); `@items.size - visible` under-counts a spaced list
        # and stops the wheel short of the bottom.
        max_base = Math.max(0, scroll_height - visible)
        row = @child_offset # selection's viewport row == where the pointer hovered
        nb = (@child_base + step).clamp(0, max_base)
        if nb != @child_base
          @child_base = nb
          # `nb + row` is the content row under the cursor; map it back to the item
          # index there so a spaced list selects the right entry.
          self.current_index = item_at_row(nb + row).clamp(0, @items.size - 1)
        else
          self.current_index = (@selected + step).clamp(0, @items.size - 1)
        end
      end

      # Moves the selection up *offset* rows (thin wrapper over `#move_selection`).
      def up(offset : Int32 = 1)
        move_selection -offset
      end

      # Moves the selection down *offset* rows (thin wrapper over `#move_selection`).
      def down(offset : Int32 = 1)
        move_selection offset
      end

      # Inserts an item showing *content* at row *index* (Qt's
      # `QListWidget#insertItem`). *index* == `#count` appends, so this does not
      # route through `#index_of`, which validates against the *existing* rows.
      def insert_item(index : Int, content : String)
        i = index.to_i
        return unless 0 <= i <= @items.size
        if i == @items.size
          return add_item content
        end
        item = create_item content
        # Slide multi-selected indices at/after the insertion point up by one.
        if @selected_indices.any? { |s| s >= i }
          @selected_indices = @selected_indices.map { |s| s >= i ? s + 1 : s }.to_set
        end
        item.top = item_row(i)
        # The inserted item shifts every later row down one slot; re-place them.
        (i...@items.size).each { |j| @items[j].top = item_row(j + 1) }
        @ritems.insert i, content
        invalidate_item_index
        @items.insert i, item
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
      def insert_item(child : String | Widget, content : String)
        i = index_of child
        return unless i
        insert_item i, content
      end

      # Replaces the text of the item at *child* (a row index, an item's text, or
      # the item box itself). No-op when *child*
      # resolves to no item, including an out-of-range row.
      def set_item(child, content : String)
        i = index_of child
        return unless i

        @items[i]?.try &.set_content(content)
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
      def set_item(child, widget : Widget)
        set_item child, content: widget.rendered_content
      end

      # Replaces every item with one per entry of *items* (reusing the existing
      # boxes where it can) and emits `Event::ItemsChanged`.
      #
      # NOTE: this is *not* the inverse of `#items`, which is `Widget`'s
      # `Array(Widget::Box)` of backing boxes; the item view's model is its text
      # rows. Read it back with `#count`/`#item`.
      def items=(items : Array(String))
        # Wholesale replacement: stale indices can't be carried over, so drop
        # the multi-selection.
        @selected_indices.clear
        original = @items.dup
        previous = @selected
        sel = @ritems[previous]?

        self.current_index = 0

        items.each_with_index do |item, i|
          if itm = @items[i]?
            itm.set_content item
          else
            add_item item
          end
        end

        # Remove only the *leftover* original items (past the end of the new
        # list) — the first `items.size` were reused above via `set_content`.
        # Must be `remove_item`, not `remove`: `remove` only unlinks from the
        # children tree, leaving `@items`/`@ritems` with stale entries.
        if original.size > items.size
          original[items.size..].each do |itm|
            remove_item itm
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
          elsif @items.size == original.size
            # Use the saved selection; `selected` was just reset to 0 above.
            self.current_index = previous
          else
            self.current_index = Math.min previous, @items.size - 1
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
        # `items[@selected]` raises `IndexError` on an empty list under Crystal's
        # strict indexing.
        return if @items.empty?
        emit Crysterm::Event::ItemActivated, items[@selected], @selected
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
        return if @items.empty?
        emit Crysterm::Event::ItemActivated, items[@selected], @selected
        emit Crysterm::Event::ItemCancelled, items[@selected], @selected
      end

      # Enables the incremental-search prompt (`/` forward, `?` backward) in the
      # key handler.
      property? search = true

      # Lazily-created one-line input shown at the bottom of the window during a
      # search (see `#start_search`).
      @search_box : Widget::LineEdit? = nil

      # Index of the first item whose tag-stripped, case-insensitive text
      # contains *query*, scanning from the current selection and wrapping;
      # `nil` when nothing matches. `backward: true` searches upward.
      #
      # No match reports `nil`, not the current selection, which a caller could
      # not tell apart from a real hit on that same row (Qt's `findItems` likewise
      # reports an empty result rather than a fallback).
      def fuzzy_find(query : String, *, backward : Bool = false) : Int32?
        return nil if @items.empty?
        q = query.downcase
        n = @items.size
        step = backward ? -1 : 1
        i = @selected
        n.times do
          i = (i + step) % n
          return i if clean_tags(@ritems[i]).downcase.includes? q
        end
        nil
      end

      # The incremental-search `LineEdit` is a *window* child, a sibling of this
      # list — `Widget#destroy` only tears down this widget and its own children,
      # so the box must be dropped explicitly or it is orphaned at the window
      # bottom for the window's lifetime.
      def destroy
        Widget.destroy_satellite @search_box
        @search_box = nil
        super
      end

      private def ensure_search_box : Widget::LineEdit
        # The box is a *window* child: after this view is reparented to another
        # window, the memoized box is stranded on the old one and the prompt shows
        # (and reads keys) on the wrong window, leaving `/` search silently dead.
        # Drop the stale satellite and rebuild on this window.
        if (box = @search_box) && !box.window?.same?(window?)
          Widget.destroy_satellite box
          @search_box = nil
        end
        @search_box ||= begin
          box = Widget::LineEdit.new(
            window: window,
            bottom: 0, left: 0, right: 0, height: 1,
          )
          box.add_css_class "search" # themed via `.search { ... }`
          window.append box
          box.hide
          box
        end
      end

      # Opens the incremental-search prompt. Typing a query and pressing Enter
      # jumps to the next matching item; Escape cancels. `backward: true`
      # searches upward.
      def start_search(*, backward : Bool = false)
        return unless search?
        return if @items.empty?

        sb = ensure_search_box
        sb.set_label(backward ? "?" : "/")
        sb.value = ""
        sb.show
        request_render

        sb.read_input do |data|
          sb.hide
          focus
          # No match leaves the cursor where it was (`#fuzzy_find` reports `nil`
          # rather than the current selection, so there is nothing to move to).
          if data && !data.empty? && (hit = fuzzy_find(data, backward: backward))
            self.current_index = hit
          end
          request_render
        end
      end

      # TODO
      # pick

      def on_keypress(e)
        visible = visible_content_rows
        # Half/page navigation steps by *items*, not rows: with `item_spacing > 0`
        # a page of `visible` rows holds only `items_per_page` items, so moving by
        # `visible` jumps ~two pages.
        per_page = items_per_page
        half = Math.max per_page // 2, 1

        # Vertical navigation (Up/Down/paging/Home-End + vi k/j/g/G) is classified
        # once in `Mixin::NavKeys`; here each intent maps onto a selection move
        # rather than a viewport scroll.
        case nav_intent(e)
        when .backward?      then up
        when .forward?       then down
        when .first?         then self.current_index = 0
        when .last?          then self.current_index = @items.size - 1
        when .half_backward? then move_selection -half
        when .half_forward?  then move_selection half
        when .page_backward? then move_selection -per_page
        when .page_forward?  then move_selection per_page
        else
          case
          # vi H/M/L target the item at the top/middle/bottom *row* of the
          # viewport; `@child_base` is a content row, so convert to an item index
          # (a bare `@child_base + …` would select a far-off item when spaced).
          when @vi && e.char == 'H'
            self.current_index = item_at_row(@child_base)
          when @vi && e.char == 'M'
            self.current_index = item_at_row(@child_base + visible // 2)
          when @vi && e.char == 'L'
            self.current_index = item_at_row(@child_base + visible - 1)
          when search? && e.char == '/'
            start_search backward: false
          when search? && e.char == '?'
            start_search backward: true
          when multi_select? && e.char == ' '
            toggle_selection @selected
          when e.key == ::Tput::Key::Enter
            activate_current
          when e.key == ::Tput::Key::Escape
            cancel_current
          else
            return
          end
        end

        # Consume the key so it doesn't also drive an ancestor, and repaint.
        e.accept
        request_render
      end

      def on_resize(e)
        visible = visible_content_rows
        # Position against the selected item's *content row* (which includes the
        # inter-item gaps), not its bare index, or a spaced, overflowing list
        # parks the base `selected * item_spacing` rows above the item.
        row = item_row(@selected)
        if visible <= 0
          # Collapsed viewport (`ivertical >= aheight`, e.g. a bordered list
          # squeezed too small): the `else` branch would compute a negative
          # `@child_offset` and an out-of-range `@child_base`. Park the selection
          # at the base with a zero offset — a valid state for a list showing no
          # rows.
          @child_base = row
          @child_offset = 0
        elsif visible >= row + 1
          @child_base = 0
          @child_offset = row
        else
          @child_base = row - visible + 1
          @child_offset = visible - 1
        end
      end
    end
  end
end
