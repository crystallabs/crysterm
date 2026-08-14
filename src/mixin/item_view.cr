require "./index_validation"
require "./nav_keys"

module Crysterm
  module Mixin
    # The "list of selectable items" concern (Qt's `QAbstractItemView`): the text
    # rows, the selection model, the current index, and the keys/mouse that move
    # them. Shared by the item-view widgets without inheritance, so a widget that
    # must root in a different base can include it standalone.
    #
    # The including type supplies a scrollable `Box`-like host: `#item_boxes` (the
    # backing item boxes, this mixin's own store) and `@ritems` (their raw text)
    # in lock-step, plus `clean_tags`, `visible_content_rows`, `scroll_to`,
    # `@child_base`/`@child_offset` and `styles`.
    #
    # The `#item_view?` override plus `#item_selected?` are the duck-typed hooks
    # the renderer keys off, so no `is_a?(List)` check is needed.
    #
    # This file holds the include-facing declarations (enums, ivars/properties,
    # `initialize`); the method bodies are split across `item_view/model.cr`
    # (items CRUD + selection model + multi-select), `item_view/interaction.cr`
    # (mouse/wheel modes, incremental search, nav keys) and `item_view/render.cr`
    # (style resolution/fallbacks, painting) — required at the bottom, mirroring
    # `text_editing.cr` + `text_editing/`.
    module ItemView
      include NavKeys
      include IndexValidation
      # For the `#<<`/`#>>` operator aliases (see `item_view/model.cr`). Included
      # again here because a standalone module doesn't inherit macros from its
      # future includers.
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

      # Backing per-item `Box` widgets, one per row, parallel to `@ritems`. This
      # is the render/geometry store the mixin (and includers) mutate; the
      # public *model* is `#items` (the texts). Lives here, not on the `Widget`
      # base, so only item views carry it.
      property item_boxes = [] of Widget::Box

      @ritems = [] of String

      # The list's item model: the raw (tag-carrying) text of each row, in order
      # (Qt's `QListWidget` string model). Symmetric with `#items=`, so
      # `list.items += ["x"]` reads, appends and writes back end-to-end. This is
      # the model, NOT the backing `Box` widgets — those are `#item_boxes`.
      def items : Array(String)
        @ritems
      end

      # Tag-carrying raw item texts, parallel to `#item_boxes`. Alias of `#items`
      # kept for callers that want the intent-revealing name; the list rebuilds
      # it internally as items are added/removed/set.
      def item_texts : Array(String)
        @ritems
      end

      # Item views are the widgets this predicate exists for; overrides the
      # `Widget` base `false` so the geometry/scroll partials treat them as
      # shrink-to-content lists.
      protected def item_view? : Bool
        true
      end

      # Number of backing item boxes, for the base geometry/scroll partials (see
      # `Widget#item_box_count`). Equal to `#count`/`@ritems.size` by the
      # lock-step invariant every mutator maintains.
      protected def item_box_count : Int32
        @item_boxes.size
      end

      # Backing store for `#current_index`.
      @selected = 0

      # How many items may be selected at once (Qt's
      # `QAbstractItemView#selectionMode`). See `SelectionMode`.
      property selection_mode : SelectionMode = SelectionMode::SingleSelection

      # Indices in the multi-selection (only meaningful when `#multi_select?`).
      # Maintained across insert/remove so marked items track their rows.
      getter selected_indices = Set(Int32).new

      # Backing store for `#non_selectable_rows`.
      @nonselectable = Set(Int32).new

      @value : String = ""

      # Lazily-built map of `clean_tags(item) => first index`, used by the
      # `#index_of(String)` fallback to avoid re-running `clean_tags` (a full gsub
      # per item) on every lookup. Invalidated by `invalidate_item_index` whenever
      # `@ritems` is mutated.
      @clean_tags_index : Hash(String, Int32)? = nil

      # Lazily-built identity map `item widget => its index in @item_boxes`. The
      # `multi_select?` render path resolves an item's index once per child per
      # frame, which as `@item_boxes.index item` is a linear scan per item ⇒
      # O(n²)/frame. Keyed by reference identity (`Reference#hash`/`#==` are by
      # `object_id`), matching `Array#index`'s `==`. Invalidated by
      # `invalidate_item_index` whenever `@item_boxes` is mutated.
      @item_index : Hash(Widget, Int32)? = nil

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
          on ::Crysterm::Event::KeyPress, ->handle_key_press(::Crysterm::Event::KeyPress)
        end

        on ::Crysterm::Event::Resize, ->handle_resize(::Crysterm::Event::Resize)
      end
    end
  end
end

require "./item_view/model"
require "./item_view/interaction"
require "./item_view/render"
