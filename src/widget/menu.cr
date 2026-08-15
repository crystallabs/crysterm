require "./box"
require "../action"
require "../mixin/item_view"
require "../mixin/nav_keys"
require "../mixin/action_watcher"

module Crysterm
  class Widget
    # A vertical menu of `Action`s.
    #
    # The (visible) actions are shown as selectable rows; arrow keys (and, with
    # `vi_keys: true`, `j`/`k`) navigate, and Enter — or a click on the highlighted
    # row — activates the selected action. Activating emits the action's
    # `Event::Triggered`, received by any listener attached via
    # `action.on(Crysterm::Event::Triggered) { ... }`. Disabled actions are
    # listed but not activated.
    #
    # In Qt, `QMenu : public QWidget` — a menu is a plain widget, **not** a
    # `QAbstractItemView` (which `CSS::Qss` maps to `List`). So `Menu` derives
    # `Box` and only *includes* `Mixin::ItemView` for item rows/navigation. Its
    # CSS identity is `Menu < Box < Widget`, so a theme's item-view rules
    # (`QAbstractItemView { background-color; … }`) don't bleed onto menus and it
    # takes the `QMenu`/window surface like other `QWidget`-derived chrome.
    #
    # ```
    # menu = Widget::Menu.new parent: window
    # quit = Action.new "Quit"
    # quit.on(Crysterm::Event::Triggered) { exit }
    # menu << quit
    # menu.focus
    # ```
    #
    # The class is split across three files, following the `textedit.cr`
    # precedent: this one holds the core class and action API,
    # `menu_popup.cr` the popup/submenu session management, and `menu_rows.cr`
    # the row building and its caches.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Menu screenshot](../../tests/widget/menu/menu.5s.apng)
    # <!-- /widget-examples:capture -->
    class Menu < Box
      include Mixin::ItemView
      include Mixin::ActionWatcher
      # A menu is an overlay: at the unstyled floor it carries a structural
      # border to separate from the content behind it (a theme's CSS, e.g.
      # qdarkstyle's `QMenu { border: 0 }`, then owns the border).
      include ::Crysterm::Overlay::Floor

      # Optional title, shown as the widget's label.
      @title : String = ""

      def title : String
        @title
      end

      # Sets the title, updating (or clearing) the rendered label on an actual
      # change.
      def title=(v : String) : String
        return v if v == @title
        @title = v
        v.empty? ? remove_label : set_label(v)
        update!
        v
      end

      # The actions in this menu, in display order. Read-only: mutate through
      # `#<<`/`#add_action`/`#add_submenu`/`#add_separator`/`#remove_action`/`#clear`, or
      # assign a whole new set with `#actions=`.
      getter actions = [] of Action

      # Replaces the whole action set, rewiring the `Changed` watchers and
      # rebuilding the rows.
      def actions=(actions : Array(Action)) : Array(Action)
        batch_update do
          clear
          actions.each { |a| self << a }
        end
        @actions
      end

      # Optional hook for a top-level menu (no `#parent_menu`) to hand horizontal
      # navigation to its owner: called with `-1` on Left (at the top-level menu)
      # and `+1` on Right when there's no submenu to move into — Right consults
      # the chain's *root* menu, so a leaf deep in a submenu still moves the
      # owner forward. A `Widget::MenuBar` sets this to switch between its menus
      # with the arrow keys. The public spelling is the block form
      # `#navigate_handler(&block)`; the raw setter is protected.
      getter navigate_handler : Proc(Int32, Nil)?
      protected setter navigate_handler

      # Sets the horizontal-navigation overflow hook via a block, e.g.
      # `menu.navigate_handler { |dir| switch_relative dir }`. The documented public
      # API (`#navigate_handler=` is protected).
      def navigate_handler(&block : Int32 ->) : Nil
        @navigate_handler = block
      end

      # Optional hook for a top-level menu's owner, called after the menu chain
      # was dismissed *by activating a leaf action* (Enter/Space/click on a
      # plain entry) — not by Escape or an outside click. Consulted on the
      # chain's *root* menu, so a leaf fired deep in a submenu still reaches
      # the owner. A `Widget::MenuBar` uses it to fully deactivate: focus
      # returns to the central area rather than resting on the bar with a lit
      # title. The public spelling is the block form `#chain_activated_handler(&block)`;
      # the raw setter is protected.
      getter chain_activated_handler : Proc(Nil)?
      protected setter chain_activated_handler

      # Sets the leaf-activation dismissal hook via a block (see the getter).
      def chain_activated_handler(&block : ->) : Nil
        @chain_activated_handler = block
      end

      # Whether the highlighted row is drawn highlighted. A menu opens with *no*
      # row highlighted (Qt-like): it appears only once the user hovers a row
      # (`#hover_item`) or presses a selection key (`#handle_key_press`), and clears
      # again on outside-click dismissal.
      @show_highlight = false

      # Cache for `#item_on_surface`: the surfaced (`bg`-filled) `Style` per
      # source-style object, valid while the menu surface `bg` is unchanged.
      # Keyed by identity — source per-state styles are stable across frames
      # until the cascade re-runs and replaces them with new objects, missing the
      # cache. Cleared when the surface `bg` changes.
      @surface_cache : Cache::Bounded(::Crysterm::Style, ::Crysterm::Style)?
      @surface_cache_bg : Int32? = nil
      @surface_cache_valid = false

      # Cache for `#separator_render_style`: the derived line style, invalidated
      # when the source `style.separator` object or the menu surface `bg` changes
      # (both change identity/value on cascade).
      @sep_style_src : ::Crysterm::Style?
      @sep_style_bg : Int32? = nil
      @sep_style_out : ::Crysterm::Style?

      def initialize(title = "", **widget)
        @title = title

        super **widget

        # Own our style: menus are often created from one shared style (e.g. a
        # menu bar's File/Edit/Help). Since per-widget visibility lives in
        # `Style`, a shared style would couple their show/hide. Dup so each menu
        # toggles only itself.
        @style = @style.try(&.dup)

        # Menus activate on a single click (open submenu / fire action), not the
        # list's two-click select-then-activate. Hovering a row selects it too
        # (see `#hover_item`).
        @activate_on_click = true
        @hover_select = true

        set_label @title unless @title.empty?
        sync_items

        # Enter (or a click on the already-selected row) emits `ItemActivated`;
        # activate the corresponding action.
        on(::Crysterm::Event::ItemActivated) { |e| activate_index e.index }
      end

      # Adds *action* to the menu (no-op if already present). `#watch_action`
      # associates it and re-renders whenever its display state changes,
      # mirroring a Qt menu tracking its `QAction`s' `changed()` signal — that is
      # what makes an external `action.checked =`/`text=` update the rows.
      def <<(action : Action)
        unless @actions.includes? action
          @actions << action
          watch_action(action) { |_e| refresh_rows; nil }
          sync_items
        end
        self
      end

      # Creates an `Action` labeled *text*, appends it, and returns it (Qt's
      # `QMenu#addAction(text)`).
      def add_action(text : String) : Action
        action = Action.new text
        self << action
        action
      end

      # :ditto: — also connecting *block* to the action's `Event::Triggered`.
      def add_action(text : String, &block : ->) : Action
        action = add_action text
        action.on(::Crysterm::Event::Triggered) { block.call }
        action
      end

      # Appends an existing *action* and returns it (Qt's
      # `QMenu#addAction(QAction*)`) — the `Action`-based counterpart to the
      # text-based overloads above; `#<<` is the same operation returning
      # `self` instead.
      def add_action(action : Action) : Action
        self << action
        action
      end

      # Appends every action in *actions*, in order (Qt's `QMenu#addActions`) —
      # distinct from `#actions=`, which clears the menu first.
      def add_actions(actions : Enumerable(Action)) : self
        batch_update { actions.each { |a| self << a } }
        self
      end

      # Creates a submenu action labeled *text* holding *actions* (empty by
      # default — fill it later through the returned action's `#menu`), appends
      # it, and returns it.
      #
      # NOT named `add_menu`, though Qt's `QMenu#addMenu` is the counterpart:
      # `Widget::MenuBar#add_menu` builds and returns a real, persistent `Menu`
      # widget, whereas a submenu here is just an `Array(Action)` on an `Action`
      # (`#open_submenu` materializes a throwaway `Menu` for it on each open).
      # The two names keep those contracts and return types apart.
      def add_submenu(text : String, actions : Array(Action) = [] of Action) : Action
        action = Action.new text
        action.menu = actions
        self << action
        action
      end

      # Appends a non-selectable separator rule and returns it (Qt's
      # `QMenu#addSeparator`, which likewise hands back the `QAction`), so it can
      # be hidden or removed by reference later.
      def add_separator : Action
        sep = Action.separator
        @actions << sep
        sep.associate self
        sync_items
        sep
      end

      # Inserts *action* at *index* in the action list (Qt's
      # `QMenu#insertAction`). Out-of-range indices clamp to the ends; a duplicate
      # is a no-op, as with `#<<`.
      def insert_action(index : Int, action : Action) : self
        return self if @actions.includes? action
        @actions.insert index.to_i.clamp(0, @actions.size), action
        watch_action(action) { |_e| refresh_rows; nil }
        sync_items
        self
      end

      # Inserts a non-selectable separator rule at *index* (Qt's
      # `QMenu#insertSeparator`), returning the separator action — parity with
      # the index-less `#add_separator` and with `#insert_action`, so it too can
      # be hidden or removed by reference later.
      def insert_separator(index : Int) : Action
        sep = Action.separator
        @actions.insert index.to_i.clamp(0, @actions.size), sep
        sep.associate self
        sync_items
        sep
      end

      # Inserts a submenu action labeled *text* holding *actions* at *index*
      # (Qt's `QMenu#insertMenu`) — parity with the index-less `#add_submenu`
      # and with `#insert_action`. See `#add_submenu` for why this isn't named
      # `insert_menu`.
      def insert_submenu(index : Int, text : String, actions : Array(Action) = [] of Action) : Action
        action = Action.new text
        action.menu = actions
        @actions.insert index.to_i.clamp(0, @actions.size), action
        watch_action(action) { |_e| refresh_rows; nil }
        sync_items
        action
      end

      # Removes *action* from the menu (Qt's `QMenu#removeAction`), dropping its
      # `Changed` handler and dissociating it.
      def remove_action(action : Action) : self
        if @actions.delete action
          unwatch_action action
          sync_items
        end
        self
      end

      # `#>>` is an operator alias mirroring `#<<`; `#remove_action` remains the
      # primary, Qt-faithful spelling.
      alias_method :>>, :remove_action

      # Removes every action (Qt's `QMenu#clear`). Overrides
      # `Mixin::ItemView#clear`, which would drop the rendered rows and leave the
      # actions behind for the next `#sync_items` to bring straight back.
      def clear : Nil
        return if @actions.empty?
        @actions.each { |a| unwatch_action a }
        @actions.clear
        sync_items
      end

      # Number of actions in the menu, separators and hidden ones included (Qt's
      # `QMenu#actions.size`). `Mixin::ItemView#count` would report only the
      # *visible* rows, which is not what the menu's own model holds.
      def count : Int32
        @actions.size
      end

      # The currently highlighted action, or `nil` when the menu is empty.
      def selected_action : Action?
        visible_actions[current_index]?
      end

      # Activates the highlighted action (as if Enter were pressed on it).
      def activate_selected
        activate_index current_index
      end

      # Reveals the highlight on the first selectable row. Keyboard-opened menus
      # (`MenuBar`'s Down/Space or menu-to-menu switching, a submenu entered
      # with Right) start with their first entry selected — Qt behavior — unlike
      # mouse-opened ones, which drop with no row highlighted until hovered.
      def select_first_action : Nil
        reveal_edge 1
      end

      # :ditto: — the *last* selectable row (`MenuBar`'s Up opens the menu
      # cycling backward, so it starts from the bottom end).
      def select_last_action : Nil
        reveal_edge -1
      end

      private def reveal_edge(dir : Int32) : Nil
        return unless i = edge_selectable(dir)
        @show_highlight = true
        self.current_index = i
        update!
      end

      # Index of the first (`dir > 0`) or last (`dir < 0`) selectable
      # (non-separator) row, or `nil` when the menu is empty or all separators.
      private def edge_selectable(dir : Int32) : Int32?
        acts = visible_actions
        n = acts.size
        return if n == 0
        from = dir > 0 ? 0 : n - 1
        Mixin::NavKeys.nearest_selectable(n, from, dir) { |i| acts[i].separator? }
      end

      # Whether a selectable row exists strictly beyond the current one in *dir*
      # — false at the list's edge, where vertical navigation wraps around.
      private def selectable_beyond?(dir : Int32) : Bool
        acts = visible_actions
        i = current_index + dir
        while 0 <= i && i < acts.size
          return true unless acts[i].separator?
          i += dir
        end
        false
      end

      # While the menu is "inactive" (dismissed by an outside click) no row is
      # highlighted; otherwise rendering defers to `Mixin::ItemView`.
      def render_style_for(item : Widget) : Style
        # A separator draws from its own `Menu::separator` sub-style (Qt's
        # `QMenu::separator`) regardless of highlight state — never selectable,
        # so never highlighted. Precomputed in `#sync_items`: O(1) set lookup.
        if @separator_items.includes? item
          return separator_render_style
        end
        # Until the highlight is revealed (hover / first nav key), draw every row
        # in its *normal* look but still via the per-item CSS style, so themed
        # colors apply. A bare `item_render_style` here would drop cascaded
        # styling and make a freshly-opened menu look disabled.
        base =
          if !@show_highlight && item.css_styled?
            item.state = ::Crysterm::WidgetState::Normal
            item.style
          elsif !@show_highlight
            item_render_style(false)
          else
            super
          end
        item_on_surface base
      end

      # A `QMenu::item { background: transparent }` row (Qt's default) resolves
      # to *no* background; but a child widget with no background paints the
      # terminal default, not the parent's surface. Fill an unset/transparent
      # item background from the menu's own, giving the Qt look without a
      # per-theme hack. Item `padding`/`border` are kept (reserved in the menu's
      # width by `#fit_to_content`).
      private def item_on_surface(st : Style) : Style
        bg = st.bg
        return st unless (bg.nil? || bg == -1) && (surface = style.bg)
        # Themed items carry a stable per-state `Style` object across frames, so
        # an identity-keyed cache holds one surfaced copy per row instead of
        # dup-ing per row per frame. A changed surface `bg` (or a cascade, which
        # mints new item styles) drops the stale entries.
        cache = @surface_cache ||= Cache::Bounded(::Crysterm::Style, ::Crysterm::Style).new(Cache::MENU_SURFACE_CAPACITY, by_identity: true)
        if !@surface_cache_valid || surface != @surface_cache_bg
          cache.clear
          @surface_cache_bg = surface
          @surface_cache_valid = true
        end
        # `Bounded#fetch` stores the block's result, so no explicit `cache[st] =`.
        cache.fetch(st) do
          out = st.dup
          out.bg = surface
          out
        end
      end

      # The style for a separator row: the `─` rule sits on the menu's own
      # surface, not a filled band of the divider color. Qt's `QMenu::separator`
      # carries the divider color in `background-color`, which becomes the line's
      # foreground when set; otherwise the menu's own foreground draws it. Border
      # dropped — the menu draws the frame.
      private def separator_render_style : Style
        sep = style.separator
        bg = style.bg
        # Reuse the derived line style while its inputs — the source
        # `style.separator` object (replaced on cascade) and the menu surface
        # `bg` — are unchanged, instead of dup-ing per separator per frame.
        if (cached = @sep_style_out) && sep.same?(@sep_style_src) && bg == @sep_style_bg
          return cached
        end
        line = sep.dup
        line.border = false
        # A separator rule that set a (divider) background different from the menu
        # surface supplies the line color; otherwise fall back to the foreground.
        sep_bg = sep.bg
        line.fg = (sep_bg && sep_bg != bg) ? sep_bg : sep.fg
        line.bg = bg
        @sep_style_src = sep
        @sep_style_bg = bg
        @sep_style_out = line
        line
      end

      # Whether *e* is a key that moves the list selection (so the first such
      # press should reveal the highlight): the keys `Mixin::ItemView#handle_key_press`
      # acts on, plus vi_keys aliases when `#vi_keys?`.
      private def selection_key?(e) : Bool
        # Vertical navigation (Up/Down/paging/Home-End + vi_keys j/k/g/G) is classified
        # once in `Mixin::NavKeys`; only vi_keys H/M/L fall outside it.
        !nav_intent(e).none? || (@vi_keys && {'H', 'M', 'L'}.includes?(e.char))
      end

      # Pointer moved onto row *i* (`Mixin::ItemView#hover_item` override, active
      # because menus set `#hover_select?`). Moves the highlight there — closing
      # any submenu anchored elsewhere — and opens the row's submenu if it has
      # one. Separators are skipped; disabled rows highlight but don't open.
      def hover_item(i : Int)
        act = visible_actions[i]?
        return unless act
        return if act.separator?

        @show_highlight = true # hovering a row reveals (and moves) the highlight
        self.current_index = i
        if act.enabled? && act.menu?
          open_submenu act unless @submenu_open && @submenu_action == act
        end
      end

      # Skips over separator rows so the highlight never rests on one. The
      # direction is inferred from whether the requested index is above or below
      # the current selection.
      def current_index=(index : Int)
        # `current_index=` does *not* enable `@show_highlight` — that's driven only by
        # user interaction (`#hover_item` / a selection key in `#handle_key_press`),
        # so a programmatic selection never lights up a row on its own.
        acts = visible_actions
        unless acts.empty?
          dir = index >= current_index ? 1 : -1
          index = skip_separators index, dir, acts
        end
        super index

        # Moving the highlight onto a different item closes a submenu anchored to
        # the previous one (clicking/selecting elsewhere dismisses the open menu).
        # Skipped while `#sync_items` is rebuilding rows (`@syncing_items`): the
        # transient index churn there must not tear down a submenu the user is
        # navigating; `#sync_items` reconciles it once the rebuild settles.
        if !@syncing_items && @submenu_open && selected_action != @submenu_action
          close_submenu
        end
      end

      # A click lands on a *raw* row index, so a click on a separator row would
      # chain `activate_item(index)` → `current_index=` (which `#skip_separators` onto
      # a neighbor) → `ItemActivated` → `activate_index`, silently firing the
      # adjacent command. Keyboard activation is unaffected: its `current_index` never
      # rests on a separator.
      def activate_item(index : Int32)
        return if @item_boxes[index]?.try { |it| @separator_items.includes? it }
        super
      end

      private def skip_separators(index : Int, dir : Int, acts : Array(Action)) : Int32
        n = acts.size
        return index.to_i if n == 0
        # Step in `dir` over separators, rescanning the opposite way at a boundary
        # so the highlight never rests on one. `nil` means an all-separator list —
        # a degenerate menu — so fall back to the clamped index: still a
        # separator, still unfireable, but in range for `#current_index=`'s `super`.
        Mixin::NavKeys.nearest_selectable(n, index.to_i, dir) { |i| acts[i].separator? } || index.clamp(0, n - 1).to_i
      end

      def handle_key_press(e)
        intent = nav_intent(e)

        # A menu opens with no row highlighted; the first selection-moving key —
        # or Enter or Space — *reveals* the highlight rather than moving/
        # activating it. Up (or End) as that first key reveals it on the *last*
        # entry, any other mover on the first — so cycling starts from the end
        # the user is heading toward, and never on a leading separator. Enter
        # must be gated here too, or it falls through to `super`
        # (`activate_current` -> `activate_index 0`) and fires the first action
        # though no row was ever shown highlighted — and Space likewise, for
        # its activate/toggle handling below.
        if !@show_highlight && (selection_key?(e) || e.key == ::Tput::Key::Enter || e.char == ' ')
          @show_highlight = true
          if intent.backward? || intent.last?
            edge_selectable(-1).try { |i| self.current_index = i }
          elsif !intent.none?
            edge_selectable(1).try { |i| self.current_index = i }
          end
          update!
          e.accept
          return
        end

        return if space_pressed e
        return if enter_on_submenu e

        # Right opens the highlighted item's submenu; Left/Escape closes this one
        # and returns focus to its parent. Handled before `super` so a submenu's
        # Escape doesn't fall through to the item view's cancel path.
        if e.key == ::Tput::Key::Right
          act = selected_action
          if act && act.enabled? && act.menu?
            open_submenu_selected act
            e.accept
            return
          elsif nav = root_menu.navigate_handler
            # No submenu to enter: hand Right to the chain owner's hook — via
            # the *root* menu, so a leaf at any submenu depth still moves e.g.
            # a `MenuBar` to the next top-level menu.
            nav.call 1
            e.accept
            return
          end
        elsif e.key == ::Tput::Key::Left
          return if dismiss_to_parent_menu e
          if (nav = @navigate_handler) && @submenu_open.nil?
            nav.call -1
            e.accept
            return
          end
        elsif e.key == ::Tput::Key::Escape
          return if dismiss_to_parent_menu e
          if @popup_mode
            hide_popup
            e.accept
            return
          end
          # A non-popup top-level menu with nothing revealed yet: swallow Escape
          # rather than letting `super` fire a `ItemCancelled` on the unhighlighted
          # item 0.
          if !@show_highlight
            e.accept
            return
          end
        elsif intent.backward? || intent.forward?
          # Moving the highlight away closes any submenu anchored to the old row.
          close_submenu if @submenu_open
          # Stepping past either end wraps to the opposite end (skipping
          # separators) instead of clamping there; in-range moves fall through
          # to the item view's normal one-step handling.
          dir = intent.forward? ? 1 : -1
          unless selectable_beyond? dir
            edge_selectable(dir).try { |i| self.current_index = i }
            update!
            e.accept
            return
          end
        end

        # Last, so navigation (including `vi_keys`), search and the branches
        # above all win over a same-letter mnemonic.
        return if mnemonic_pressed e

        super
      end

      # A bare mnemonic letter (`"&New"` → `n`) pressed anywhere in the open
      # menu activates its row, highlight revealed or not (Qt; returns whether
      # it consumed *e*). Row semantics match the menu's other activation keys:
      # a submenu row opens with its first child selected, a checkable row
      # toggles in place (our Space divergence from Qt, kept consistent here),
      # a leaf fires and dismisses the chain. The first matching row wins on
      # duplicate mnemonics. Plain unmodified characters only — an Alt chord
      # belongs to the `MenuBar`'s title mnemonics, and navigation/search keys
      # were already offered every other branch first.
      private def mnemonic_pressed(e) : Bool
        c = e.char
        return false if c == '\0' || e.key || e.alt? || e.ctrl?
        return false unless nav_intent(e).none?
        down = c.downcase
        acts = visible_actions
        i = acts.index { |a| !a.separator? && a.enabled? && a.mnemonic == down }
        return false unless i
        @show_highlight = true
        self.current_index = i
        act = acts[i]
        if act.menu?
          open_submenu_selected act
        elsif act.checkable?
          act.activate
        else
          activate_index i
        end
        e.accept
        update!
        true
      end

      # Space on a highlighted row (returns whether it consumed *e*): a
      # *checkable* action toggles in place, leaving the menu open — so several
      # options can be flipped in one visit (the GTK check-menu-item behavior,
      # and the Space-toggles-a-checkbox muscle memory of terminal forms; a
      # deliberate divergence from Qt, which dismisses on any activation). The
      # toggle is the same `Action#activate` as the normal path — full
      # Toggled/Triggered semantics — only the close is skipped. On anything
      # else Space acts exactly as Enter: a submenu row opens with its first
      # child selected (`#open_submenu_selected`, shared with Right/Enter), a
      # leaf fires and dismisses the chain. Enter and click keep
      # activate-and-close even on checkable rows. With the highlight not yet
      # revealed, Space is instead a reveal key — handled by the gate at the
      # top of `#handle_key_press`, never here.
      private def space_pressed(e) : Bool
        return false unless e.char == ' ' && @show_highlight
        act = selected_action
        if act && act.enabled? && act.menu?
          open_submenu_selected act
        elsif act && act.checkable? && act.enabled?
          act.activate
        else
          activate_selected
        end
        e.accept
        true
      end

      # Enter on a highlighted submenu row (returns whether it consumed *e*):
      # routed through `#open_submenu_selected` so it behaves exactly like
      # Right and Space there. Leaf rows are deliberately NOT handled here —
      # they fall through to the item view's Enter (`activate_current` →
      # `activate_index`), which fires the action and dismisses the chain.
      private def enter_on_submenu(e) : Bool
        return false unless e.key == ::Tput::Key::Enter && @show_highlight
        act = selected_action
        return false unless act && act.enabled? && act.menu?
        open_submenu_selected act
        e.accept
        true
      end

      # Opens *act*'s submenu the keyboard way — with its first child selected
      # (Qt), unlike hover-opened ones — shared by Right, Enter and Space on a
      # submenu row, so the three behave identically. Invoked while *act*'s
      # submenu is already open, it just re-selects the first child instead of
      # reopening (or click-style toggling it closed: with focus already inside
      # the child, a repeat press of these keys never lands back here anyway).
      private def open_submenu_selected(act : Action) : Nil
        open_submenu act unless @submenu_open && @submenu_action == act
        @submenu_open.try &.select_first_action
      end

      # Escape (and any cancel gesture) must not fire the highlighted action.
      # `Mixin::ItemView#cancel_current` emits BOTH `ItemActivated` and `ItemCancelled`,
      # and this menu treats `ItemActivated` as activation, so the inherited cancel
      # path would run the highlighted — possibly destructive — action. Emit only
      # `ItemCancelled`, and reset the revealed highlight / open submenu here since
      # `#hide_popup` no-ops for an embedded menu.
      def cancel_current
        # Guard against `IndexError` on an empty list.
        return if @item_boxes.empty?
        close_submenu if @submenu_open
        @show_highlight = false
        emit ::Crysterm::Event::ItemCancelled, @item_boxes[current_index], current_index
        update!
      end

      def destroy
        hide_popup
        close_submenu
        # Drop every per-action `Changed` handler and association, so destroying
        # this menu (including submenus rebuilt on each open/close) leaves no
        # stale handler running against a destroyed widget, nor a dead `Menu`
        # pinned in `action.associated_widgets`. `#unwatch_action` dissociates
        # every action, covering separators — associated but never watched.
        @actions.each { |a| unwatch_action a }
        @actions.clear
        super
      end
    end
  end
end

require "./menu/popup"
require "./menu/rows"
