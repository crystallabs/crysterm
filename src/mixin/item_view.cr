require "./nav_keys"

module Crysterm
  module Mixin
    # The "list of selectable items" concern, extracted from `Widget::List` so
    # the item model can be shared without inheritance.
    #
    # Mirrors Qt's `QAbstractItemView` siblings (`QListWidget`, `QTreeWidget`,
    # `QTableView`): `List`/`Tree`/`ListTable`/`ComboBox::Popup`/`FileManager`
    # derive `AbstractItemView` and `include` this module. `Menu` — a `Box`, not
    # an item view — includes it standalone to reuse the row machinery without
    # becoming an `AbstractItemView`. `List` itself includes it directly too,
    # like `Input` includes `Mixin::Interactive`.
    #
    # The `@_is_list` flag plus `#item_selected?` (overridden here) are the
    # duck-typed hooks the renderer keys off — see `Widget#item_selected?` and
    # `widget_rendering.cr` — so no `is_a?(List)` check is needed.
    module ItemView
      include NavKeys

      # How a mouse-wheel notch is interpreted (see `#wheel_scroll`). The two
      # drop-down popups (`ComboBox::Popup`, `Completer::Popup`) used to each
      # override `#wheel_scroll` with a byte-identical body; this flag replaces
      # that copy-paste — they just set `wheel_mode = ScrollViewUnderPointer`.
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

      property ignore_keys = true
      property scrollable = true
      # Auto-show the scroll bar when items overflow (Qt `AsNeeded`); thumb size
      # comes from `#get_scroll_height`. Inherited by `Tree`.
      @scrollbar_policy = Widget::ScrollBarPolicy::AsNeeded

      property _list_initialized = false

      property ritems = [] of String
      property selected = 0

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
      # this is just *row*. Used wherever a viewport/content *row* must be mapped
      # back to an item *index* (vi H/M/L, wheel scroll, hover clamp), which naive
      # `@child_base`-as-index arithmetic conflated once `item_spacing > 0`.
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

      # Total content height in rows, including inter-item gaps, so scrollbar/
      # overflow logic sees the real extent (`_scroll_bottom` otherwise counts
      # items, ignoring spacing). Unchanged when not spaced.
      def get_scroll_height
        base = super
        return base if @item_spacing.zero? || @items.empty?
        Math.max(base, item_row(@items.size - 1) + 1)
      end

      # Spaced extent for the scroll clamp/thumb: the base `_scroll_bottom`
      # (`widget_scrolling.cr`) returns `@items.size` for lists, ignoring
      # `item_spacing`, so `clamp_child_base_to_content`'s `_scroll_bottom -
      # visible` would rein the base in too far and hide the last item(s) of a
      # spaced, overflowing list. Report the same spaced height as
      # `#get_scroll_height` so the clamp reaches the true bottom.
      def _scroll_bottom
        base = super
        return base if @item_spacing.zero? || @items.empty?
        Math.max(base, item_row(@items.size - 1) + 1)
      end

      # When true, a single mouse click on an item activates it (rather than the
      # default two-click select-then-activate). Set by `Widget::Menu`.
      property? activate_on_click : Bool = false

      # When true, moving the pointer over a row selects it (no click required),
      # like desktop menus. Off for plain lists; set by `Widget::Menu`. Per-row
      # hook is `#hover_item`.
      property? hover_select : Bool = false

      # Whether more than one item can be selected at once (like Qt's
      # `QAbstractItemView::MultiSelection`). When on, Space toggles the current
      # item's membership in `#selected_indices` (cursor still moves with arrow
      # keys). When off, only the cursor item is highlighted.
      property? multi_select : Bool = false

      # Indices in the multi-selection (only meaningful when `#multi_select?`).
      # Maintained across insert/remove so marked items track their rows.
      getter selected_indices = Set(Int32).new

      # Tag-stripped text of the currently selected item (`""` when empty).
      # Kept in sync by `#selekt`; used e.g. by `Widget::Form` value collection.
      getter value : String = ""

      # Lazily-built map of `clean_tags(item) => first index`, used by the
      # `get_item_index(String)` fallback to avoid re-running `clean_tags` (a
      # full gsub per item) on every lookup. Invalidated by `invalidate_item_index`
      # whenever `@ritems` is mutated.
      @clean_tags_index : Hash(String, Int32)? = nil

      @_is_list = true
      @interactive = true

      # React to mouse: click an item to select it (click the selected one to
      # activate it), scroll the selection with the wheel. Wired up in
      # `#create_item` when enabled.
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
      # The list draws its own border around the whole widget, so individual
      # items must never carry one — the non-selected branch of
      # `::Crysterm::Style#item` falls back to the list's own style (`@item || self`),
      # which would otherwise make every item draw a nested border. The
      # selected branch (`styles.selected`) is already border-less but runs
      # through the same guard for symmetry. See `Widget#_render`, which calls this.
      def item_render_style(selected : Bool) : ::Crysterm::Style
        return without_border(style.item) unless selected
        # Fuses the two transforms the selected style needs (strip border, and
        # force reverse-video at the unstyled floor) into a single `#dup`, instead
        # of the old `selection_fallback(without_border(...))` which dup'd twice
        # and discarded the first copy. `styles.selected` itself is never mutated
        # in place, and nothing is cached across frames.
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
      # for non-CSS-styled items (see `#render_style_for`); themed selections
      # (`Box:selected`) are never touched.
      private def selection_visibly_styled? : Bool
        return false unless styles.own_selected?
        styles.selected.visibly_styled?
      end

      # Returns *st* with reverse-video forced on when the selection has no
      # visible styling of its own, so the cursor row stays distinguishable with
      # no theme active. Delegates to `Style#with_reverse_fallback`, which dups
      # before toggling so the shared style is never mutated in place. Returns
      # *st* untouched when already visibly styled.
      private def selection_fallback(st : ::Crysterm::Style) : ::Crysterm::Style
        return st if selection_visibly_styled?
        st.with_reverse_fallback
      end

      # Returns *base* with any border stripped: *base* untouched when borderless
      # (no allocation), else a borderless `#dup`. Items must never carry the
      # list's border — it would nest stray line-drawing chars and reserve
      # `iwidth`, shrinking the item's content area. Shared by the item-style
      # paths here and in `ListTable`/`Menu` (subclasses of `List`).
      protected def without_border(base : ::Crysterm::Style) : ::Crysterm::Style
        return base unless base.border.any?
        borderless = base.dup
        borderless.border = false
        borderless
      end

      # Resolves the `::Crysterm::Style` an item box should render with. Single
      # entry point called from `Widget#_render`; subclasses (e.g.
      # `Widget::ListTable`, for alternating rows) override it.
      #
      # The cursor item gets the full `selected` highlight. In `#multi_select?`
      # mode the *other* checked items are underlined so they read as selected
      # without being confused with the cursor (mirrors Qt's distinct current-item
      # vs. selected-set display).
      def render_style_for(item : Widget) : ::Crysterm::Style
        # CSS-styled item (e.g. `List Box`, `Item:nth-child(even)`): use the
        # item's own cascade-computed style, reflecting selection through its
        # widget state so `:selected` rules apply.
        if item.css_styled?
          # Multi-select: cursor item gets the full `:selected` highlight, other
          # checked items stay normal but underlined.
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

        # Fast path: no multi-selection, so the only "selected" item is the
        # cursor — O(1) array compare, no scan.
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
      # or a `List:selected` rule). Without this, list-level selection colors
      # (on `styles.selected`, not the item's style) would never reach the
      # window. No-op unless a distinct selected style was set.
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

        i = @items.index item
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

      # A `List` has a fixed viewport, so "scrollable right now" must be a real
      # content-vs-height overflow test, not the `@resizable` always-scrollable
      # short-circuit it would otherwise inherit (which made an `AsNeeded`
      # scroll bar appear even when every item fits). Mirrors
      # `PlainTextEdit#really_scrollable?`.
      def really_scrollable?
        content_overflows_height?
      end

      # Keeps every item's right-edge reservation in lock-step with the vertical
      # scroll bar's *current* presence, each frame. Items bake `right` at
      # creation (`#create_item`), but whether the bar shows can change later
      # (list grows past viewport, `#set_items` reuses old item widgets, resize,
      # etc.). A stale `right: 0` would let a shown bar overpaint the last
      # content column; a stale reservation would waste a column the bar no
      # longer needs. `right=` is a no-op when unchanged. Items created resizable
      # carry `right: nil` and are left alone.
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
      def create_item(content, window = ::Crysterm::Window.global, align : ::Tput::AlignFlag | Shorthands = @align, top = 0, left = 0, right = content_margin_x, parse_tags = @parse_tags, height = 1, focus_on_click = false, normal_resizable = false, width = nil, alpha = style.alpha) # XXX hover_effects, focus_effects

        if @resizable || normal_resizable
          right = nil
        end

        # Items must not carry the list's border in their *layout* either:
        # `#item_render_style` strips it for drawing, but a border left on the
        # item's own style still reserves `iwidth`, shrinking the content area
        # (e.g. a tight popup menu showing "Abo" instead of "About"). Give items
        # a borderless base style so geometry matches.
        item_style = style
        item_style = without_border item_style if item_style.border.any?
        # An item's own style must not carry the list's *hidden* state: a style
        # captured while the list is hidden would keep `visible: false` and never
        # reappear when shown (e.g. menu rows added after `hide`). Dup only if
        # still pointing at the list's own style, so this never flips the list
        # itself visible.
        item_style = item_style.dup if item_style.same?(style)
        item_style.visible = true

        item = Widget::Box.new(content: content, window: window, align: align, top: top, left: left, right: right, parse_tags: parse_tags, height: 1, focus_on_click: focus_on_click, width: width, style: item_style)
        # XXX above: alpha

        if mouse?
          # Default: click selects, clicking the already-selected one activates
          # (Blessed-style two-click). `#activate_on_click?` (menus) makes a
          # single click both select and activate.
          item.on(::Crysterm::Event::Click) do
            if i = @items.index item
              # Honor the list's own `#focus_on_click?` opt-out, exactly as
              # `Window#dispatch_mouse`'s automatic click-to-focus does. A
              # focus-declining list (e.g. a `Completer` drop-down, whose owning
              # text box must keep focus so typing keeps filtering) would
              # otherwise be pulled into focus here — blurring the box, tearing
              # down its read mode, and leaving it focused-but-uneditable.
              focus if focus_on_click?
              if activate_on_click? || i == @selected
                enter_selected i
              else
                selekt i
              end
              request_render
            end
          end

          # Wheel over a row scrolls the list; `#accept`s so the window's default
          # scroll-the-view behavior doesn't also fire. Routed through
          # `#wheel_scroll` so a subclass can give the wheel its own semantics
          # (e.g. a hover-select drop-down scrolls the view under a stationary
          # pointer) without disturbing the arrow-key path.
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

          # With `#hover_select?` (menus), moving onto a row highlights it via
          # the overridable `#hover_item`.
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
        item.top = item_row(@items.size)

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

        (i...@items.size).each { |j| @items[j].top = item_row(j) }

        # Keep the multi-selection aligned: drop the removed index, slide
        # everything past it down by one.
        if @selected_indices.includes?(i) || @selected_indices.any? { |s| s > i }
          @selected_indices = @selected_indices.compact_map do |s|
            next nil if s == i
            s > i ? s - 1 : s
          end.to_set
        end

        # Keep the single-selection cursor on the same logical item. Removing a
        # row before the cursor shifts later rows down by one, so the cursor
        # must slide too — mirrors the multi-selection slide above. Without
        # this, `@selected` would silently jump to the next item or point past
        # the end. Removing the selected row itself selects the row before it.
        if i < selected
          selekt selected - 1
        elsif i == selected
          # When the removed row was first (`i == 0`), the cursor stays at index
          # 0 (now holding the old next row) — same `@selected` value, so
          # `#selekt`'s unchanged-index short-circuit would skip refreshing
          # `@value`/emitting `SelectItem`. Clear the latch to force a full
          # re-run. No-op for `i > 0`, where the index actually changes.
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
        index[child]? || -1
      end

      # Drops the cached `clean_tags` index so it's rebuilt fresh next lookup.
      # Called from every method that mutates `@ritems`.
      private def invalidate_item_index
        @clean_tags_index = nil
      end

      # Accepts any `Widget` (not only `Widget::Box`) so callers holding a
      # `child : Widget` resolve here. Returns -1 when not found, matching the
      # `Int`/`String` overloads.
      def get_item_index(child : Widget)
        (@items.index child) || -1
      end

      def selekt(index : Int)
        return unless interactive?

        if @items.empty?
          @selected = 0
          @value = ""
          # Clear the latch so re-populating the list re-runs the body below.
          # Otherwise emptying a list leaves `@selected == 0` AND
          # `@_list_initialized == true`, so `append_item`'s `selekt 0` for the
          # first new row hits the unchanged-index short-circuit and skips
          # refreshing `@value`/emitting `SelectItem`.
          @_list_initialized = false
          scroll_to 0
          return
        end

        # Safe because the empty-list guard above returns early and `index` is
        # clamped to a valid slot; the `@ritems[@selected]` read below relies on
        # the `@items.size == @ritems.size` invariant every mutator maintains.
        index = index.clamp(0, @items.size - 1)

        return if @selected == index && @_list_initialized
        @_list_initialized = true

        @selected = index
        @value = clean_tags @ritems[@selected]

        # Gate on having been laid out, not on having a `#parent`: a top-level
        # widget appended straight to a `Window` has no `#parent` (`Window#insert`
        # sets `window=`, not `parent=`), so an `unless @parent` guard would
        # silently skip `scroll_to`/`SelectItem` for window-level lists. `@lpos`
        # is nil only until the first render.
        return unless @lpos

        # Scroll to the item's *content row*, not its bare index: with
        # `item_spacing > 0` the item sits at `item_row(@selected) ==
        # @selected * (1 + item_spacing)`, so `scroll_to @selected` landed
        # `@selected * item_spacing` rows short.
        scroll_to item_row(@selected)

        emit ::Crysterm::Event::SelectItem, @items[@selected], @selected
      end

      def selekt(widget : Widget)
        if i = @items.index(widget)
          selekt i
        end
      end

      # Hook invoked when the pointer moves onto item *i* and `#hover_select?` is
      # on. *i* is the item's absolute index (`Window#widget_at` hit-tests against
      # painted geometry, so a scrolled list reports the real entry under the
      # pointer, not a viewport row). Selecting it directly is therefore correct at
      # any scroll offset; the clamp to the visible window `[child_base,
      # child_base + visible - 1]` only guards the fringe where an item box painted
      # right at the viewport's edge is still hit-testable one row past the last
      # fully-shown row — so a hover there parks on the last visible entry instead
      # of jumping to an off-screen one. `Widget::Menu` overrides this to also
      # open/close submenus.
      def hover_item(i : Int)
        vis = visible_content_rows
        vis = 1 if vis < 1
        # Clamp to the visible *item* range: `@child_base`/`vis` are content rows,
        # so with `item_spacing > 0` a bare `clamp(@child_base, …)` would compare
        # an item index against row bounds and snap a legitimately-visible item to
        # a different one. Convert the row bounds to item indices first.
        selekt i.clamp(item_at_row(@child_base), item_at_row(@child_base + vis - 1))
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
        # `remove_item` only accepts a `Widget`, not an `Int` index.
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

      # Handles one mouse-wheel notch (*dir* is `-1` up / `+1` down). Branches on
      # `#wheel_mode`: `MoveSelection` (default) treats the wheel like the arrow
      # keys — two rows per notch, scrolling only to keep the selection visible;
      # `ScrollViewUnderPointer` scrolls the viewport under a stationary pointer
      # (drop-downs), keeping the selection on the entry under the cursor.
      def wheel_scroll(dir : Int32) : Nil
        if @wheel_mode.scroll_view_under_pointer?
          scroll_view_under_pointer dir
        else
          move dir * 2
        end
      end

      # The `ScrollViewUnderPointer` body (used by the drop-down popups). Shifts
      # the viewport one row (`#child_base`) and re-selects whatever entry lands
      # under the cursor — i.e. the selection's current viewport row
      # (`@child_offset`, which `#hover_item` keeps pinned to the pointer). This
      # makes the wheel and hover-select agree on a single rule ("selected ==
      # entry under the cursor") instead of the wheel nudging the selection only
      # for the next hover to snap it back (the "jumps back under the cursor"
      # bug). At the top/bottom edges, where the view can no longer scroll, it
      # steps the selection within the visible page so the first/last entries
      # stay reachable by the wheel alone.
      private def scroll_view_under_pointer(dir : Int32) : Nil
        return if dir == 0 || @items.empty?
        step = dir > 0 ? 1 : -1
        visible = visible_content_rows
        visible = 1 if visible < 1
        # The scrollable extent is in content *rows* (`get_scroll_height` includes
        # the inter-item gaps); `@items.size - visible` under-counts a spaced list
        # and stopped the wheel short of the bottom.
        max_base = Math.max(0, get_scroll_height - visible)
        row = @child_offset # selection's viewport row == where the pointer hovered
        nb = (@child_base + step).clamp(0, max_base)
        if nb != @child_base
          @child_base = nb
          # `nb + row` is the content row under the cursor; map it back to the item
          # index there so a spaced list selects the right entry.
          selekt item_at_row(nb + row).clamp(0, @items.size - 1)
        else
          selekt (@selected + step).clamp(0, @items.size - 1)
        end
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
          # Keep cached `#value` in sync when the *selected* row's text changes
          # in place — `#selekt` early-returns on an unchanged index, so it
          # wouldn't otherwise refresh `@value`.
          @value = clean_tags(content) if i == @selected
        end
      end

      def set_item(child, widget : Widget)
        set_item child, content: widget.get_content
      end

      def set_items(items)
        # Wholesale replacement: stale indices can't be carried over, so drop
        # the multi-selection.
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

        # Remove only the *leftover* original items (past the end of the new
        # list) — the first `items.size` were reused above via `set_content`.
        # Use `remove_item`, not `remove`: `remove` only unlinks from the
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
            selekt sel
          elsif @items.size == original.size
            # Use the saved selection; `selected` was just reset to 0 above.
            selekt selekted
          else
            selekt Math.min selekted, @items.size - 1
          end
        end

        # Rows were reused in place above, so the selection may land on the same
        # index whose text just changed — `selekt`'s unchanged-index
        # short-circuit wouldn't refresh `@value`. Sync it explicitly. `""` when
        # the list ended up empty.
        @value = @ritems[@selected]?.try { |r| clean_tags r } || ""

        emit Crysterm::Event::SetItems
      end

      def enter_selected(i)
        selekt i
        enter_selected
      end

      def enter_selected
        # `items[selected]` would raise `IndexError` on an empty list (Blessed's
        # JS yields a benign `undefined` here; Crystal's strict indexing crashes,
        # so guard instead).
        return if @items.empty?
        emit Crysterm::Event::ActionItem, items[selected], selected
        emit Crysterm::Event::SelectItem, items[selected], selected
      end

      def cancel_selected(i)
        selekt i
        cancel_selected
      end

      def cancel_selected
        # See `#enter_selected`: guard against `IndexError` on an empty list.
        return if @items.empty?
        emit Crysterm::Event::ActionItem, items[selected], selected
        emit Crysterm::Event::CancelItem, items[selected], selected
      end

      # Enables the incremental-search prompt (`/` forward, `?` backward) in the
      # key handler.
      property? search = true

      # Lazily-created one-line input shown at the bottom of the window during a
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
          return i if clean_tags(@ritems[i]).downcase.includes? q
        end
        selected
      end

      # The incremental-search `LineEdit` is appended to the *window* (a sibling
      # of this list, not a child), so `Widget#destroy` — which only tears down
      # this widget and its own children — would leave it orphaned at the window
      # bottom for the window's lifetime. Drop it explicitly here.
      def destroy
        Widget.destroy_satellite @search_box
        @search_box = nil
        super
      end

      private def ensure_search_box : Widget::LineEdit
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
        visible = visible_content_rows
        # Half/page navigation steps by *items*, not rows: with `item_spacing > 0`
        # a page of `visible` rows holds only `items_per_page` items, so moving by
        # `visible` jumped ~two pages.
        per_page = items_per_page
        half = Math.max per_page // 2, 1

        # Vertical navigation (Up/Down/paging/Home-End + vi k/j/g/G) is
        # classified once in `Mixin::NavKeys` and shared with `Interactive`; here
        # each intent maps onto a selection move rather than a viewport scroll.
        case nav_intent(e)
        when .backward?      then up
        when .forward?       then down
        when .first?         then selekt 0
        when .last?          then selekt @items.size - 1
        when .half_backward? then move -half
        when .half_forward?  then move half
        when .page_backward? then move -per_page
        when .page_forward?  then move per_page
        else
          case
          # vi H/M/L target the item at the top/middle/bottom *row* of the
          # viewport; `@child_base` is a content row, so convert to an item index
          # (a bare `@child_base + …` would select a far-off item when spaced).
          when @vi && e.char == 'H'
            selekt item_at_row(@child_base)
          when @vi && e.char == 'M'
            selekt item_at_row(@child_base + visible // 2)
          when @vi && e.char == 'L'
            selekt item_at_row(@child_base + visible - 1)
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
        end

        # Consume the key so it doesn't also drive an ancestor (e.g. a `Form`'s
        # own vi `j`/`k`), and repaint.
        e.accept
        request_render
      end

      def on_resize(e)
        visible = visible_content_rows
        # Position against the selected item's *content row* (which includes the
        # inter-item gaps), not its bare index; otherwise a spaced, overflowing
        # list parks the base `selected * item_spacing` rows above the item.
        row = item_row(selected)
        if visible <= 0
          # Collapsed viewport (`iheight >= aheight`, e.g. a bordered list
          # squeezed too small): the `else` branch below would compute
          # `@child_offset = visible - 1` (negative) and an out-of-range
          # `@child_base`. Park the selection at the base with a zero offset
          # instead — a valid state for a list showing no rows.
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
