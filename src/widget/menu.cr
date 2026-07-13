require "./box"
require "../action"
require "../mixin/item_view"
require "../mixin/action_bar"
require "../mixin/action_watcher"

module Crysterm
  class Widget
    # A vertical menu of `Action`s.
    #
    # The (visible) actions are shown as selectable rows; arrow keys (and, with
    # `vi: true`, `j`/`k`) navigate, and Enter — or a click on the highlighted
    # row — activates the selected action. Activating emits the action's
    # `Event::Triggered`, received by any listener attached via
    # `action.on(Crysterm::Event::Triggered) { ... }`. Disabled actions are
    # listed but not activated.
    #
    # In Qt, `QMenu : public QWidget` — a menu is a plain widget, **not** a
    # `QAbstractItemView` (which `CSS::Qss` maps to `List`). So `Menu` derives
    # `Box` and only *includes* `Mixin::ItemView` for item rows/navigation,
    # rather than inheriting `List`. Its CSS identity is `Menu < Box < Widget`,
    # matching Qt's hierarchy: a theme's item-view rules (`QAbstractItemView {
    # background-color; … }`) don't bleed onto menus, so it takes the
    # `QMenu`/window surface like other `QWidget`-derived chrome
    # (`QMenuBar`/`QStatusBar`). (`Tree`/`ListTable`/the combo `Popup` are real
    # `QAbstractItemView`s.)
    #
    # ```
    # menu = Widget::Menu.new parent: window
    # quit = Action.new "Quit"
    # quit.on(Crysterm::Event::Triggered) { exit }
    # menu << quit
    # menu.focus
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Menu screenshot](../../tests/widget/menu/menu.5s.apng)
    # <!-- /widget-examples:capture -->
    class Menu < Box
      include Mixin::ItemView
      # Shared "watch each action's `Changed` signal + own the host association"
      # concern (the hash, `associate`/`dissociate`, teardown), passing the
      # menu-specific refresh body per action (see `#<<`).
      include Mixin::ActionWatcher
      # A menu is an overlay: at the unstyled floor it carries a structural
      # border to separate from the content behind it (a theme's CSS, e.g.
      # qdarkstyle's `QMenu { border: 0 }`, then owns the border).
      include Mixin::Overlay

      # Optional title, shown as the widget's label.
      property title : String = ""

      # The actions in this menu, in display order.
      property actions = [] of Action

      # Caps the auto-sized (popup/submenu) height to at most this many item rows,
      # scrolling the remainder — mirrors `ComboBox#max_visible`. `nil` (default)
      # fits every row. A long dropdown (e.g. a `Calendar`'s ±100 year list)
      # sets this so the popup stays on-window and scrolls to its selection.
      property max_visible_rows : Int32? = nil

      # The menu this one is a submenu of (`nil` for a top-level menu). Set when a
      # submenu is opened; used to route Left/Escape back to the parent.
      property parent_menu : Menu?

      # Optional hook for a top-level menu (no `#parent_menu`) to hand horizontal
      # navigation to its owner: called with `-1` on Left and `+1` on Right when
      # there's no submenu to move into. A `Widget::MenuBar` sets this to switch
      # between its menus with the arrow keys.
      property on_navigate : Proc(Int32, Nil)?

      # Extra region counted as "inside" for the modal input-grab (see
      # `Widget#grab_contains?`), on top of this menu's own submenu chain. A
      # `Widget::MenuBar` sets it to its own strip so hovering the bar's titles
      # still switches menus while one is open.
      property grab_region : Proc(Int32, Int32, Bool)?

      # Marks *block* as an extra region counted as "inside" this menu's modal
      # grab (see `#grab_contains?`), on top of its own submenu chain — so a
      # press there (e.g. the owning `MenuBar`'s title strip, a `ToolButton`, a
      # `Calendar`'s nav bar) is *not* read as a click-away that auto-dismisses
      # the menu. A readable alias for assigning the raw `#grab_region` proc.
      def treat_as_inside(&block : Int32, Int32 -> Bool) : Nil
        @grab_region = block
      end

      # While open, the grab region is the whole submenu chain plus any extra
      # `#grab_region` (e.g. the owning menu bar).
      def grab_contains?(x : Int32, y : Int32) : Bool
        return true if in_chain? x, y
        if gr = @grab_region
          gr.call x, y
        else
          false
        end
      end

      # The currently-open child submenu, if any, and the action that opened it.
      @submenu_open : Menu?
      @submenu_action : Action?

      # The item box that opened the current submenu. A click on it toggles the
      # submenu (via `#activate_index`), so the outside-click watcher leaves it
      # alone rather than fighting that toggle.
      @submenu_anchor : Widget?

      # Whether the highlighted row is drawn highlighted. A menu opens with *no*
      # row highlighted (Qt-like): it appears only once the user hovers a row
      # (`#hover_item`) or presses a selection key (`#on_keypress`), and clears
      # again on outside-click dismissal.
      @show_highlight = false

      # The item boxes that render as separator rules, rebuilt once per
      # `#sync_items`. Lets `#render_style_for` decide "is this row a
      # separator?" with an O(1) set lookup instead of a per-row scan every frame.
      @separator_items = Set(Widget).new

      # Visible-action snapshot and the per-row left/right text columns, rebuilt
      # only in `#sync_items` (i.e. on structural/visibility/label change), not
      # per frame. `#render` calls `#fit_width`/`#fit_height`/`#size_rows` every
      # frame; recomputing `@actions.select &.visible?` and `#row_columns` there
      # was pure per-frame garbage. See ALLOCS.md group J (J2/J4).
      @visible_actions = [] of Action
      @row_lefts = [] of String
      @row_rights = [] of String

      # Reused scratch for the separator row-index array handed to `#dock_rows`
      # each frame, instead of a throwaway `compact_map` (ALLOCS.md J1).
      @dock_rows_buf = [] of Int32

      # `#size_rows` dirty guard: the inner width it last laid out at, and a flag
      # set whenever the rows themselves changed (`#sync_items`). When neither
      # changed, the per-row content strings are identical, so the whole layout
      # loop (and its two allocations per row) is skipped (ALLOCS.md J2/J3).
      @last_laid_inner : Int32 = -1
      @rows_dirty = true

      # Cache for `#item_on_surface`: the surfaced (`bg`-filled) `Style` per
      # source-style object, valid while the menu surface `bg` is unchanged.
      # Source per-state styles are stable across frames (until the cascade
      # re-runs, which replaces them with new objects, missing the identity
      # cache); keyed by identity. Cleared when the surface `bg` changes
      # (ALLOCS.md J5).
      @surface_cache : Cache::Bounded(::Crysterm::Style, ::Crysterm::Style)?
      @surface_cache_bg : Int32? = nil
      @surface_cache_valid = false

      # Cache for `#separator_render_style` (ALLOCS.md J6): the derived line
      # style, invalidated when the source `style.separator` object or the menu
      # surface `bg` changes (both change identity/value on cascade).
      @sep_style_src : ::Crysterm::Style?
      @sep_style_bg : Int32? = nil
      @sep_style_out : ::Crysterm::Style?

      # Click-away dismissal for the submenu chain, installed (on the top-level
      # menu only) while a submenu is open, to dismiss the chain when the user
      # clicks away — e.g. switching tabs. A shared `Overlay::DismissSession`
      # with *no* grab (`grab_owner: nil`) — a `#popup`/`MenuBar` grab is taken
      # separately by the popup session below.
      @submenu_session : Crysterm::Overlay::DismissSession?

      # Modal grab + click-away dismissal installed while shown as a `#popup`
      # context menu, to dismiss the whole popup when the user clicks outside it.
      # Same `Overlay::DismissSession` object `Mixin::Popup`/`Completer` use.
      @popup_session : Crysterm::Overlay::DismissSession?

      def initialize(title = "", keys = nil, **widget)
        # `keys` is absorbed: an item view always enables key handling.
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

        # Enter (or a click on the already-selected row) emits `ActionItem`;
        # activate the corresponding action.
        on(::Crysterm::Event::ActionItem) { |e| activate_index e.index }
      end

      # Whether this menu is being shown as a floating context menu (see
      # `#popup`), so it dismisses itself on outside click / after a leaf fires.
      @popup_mode = false

      # Adds *action* to the menu (no-op if already present). `#watch_action`
      # (from `Mixin::ActionWatcher`) associates it and re-renders whenever its
      # display state changes, mirroring a Qt menu tracking its `QAction`s'
      # `changed()` signal — without which external `action.checked =`/`text=`/
      # `enabled=`/`visible=` wouldn't update rows.
      def <<(action : Action)
        unless @actions.includes? action
          @actions << action
          watch_action(action) do |_e|
            # Preserve the highlighted row across the rebuild (item count can
            # shift when visibility toggles).
            sel = selected
            sync_items
            selekt sel
            request_render
            nil
          end
          sync_items
        end
        self
      end

      # Creates an `Action` labeled *text*, appends it, and returns it (Qt's
      # `QMenu#addAction(text)`).
      def add(text : String) : Action
        action = Action.new text
        self << action
        action
      end

      # :ditto: — also connecting *block* to the action's `Event::Triggered`.
      def add(text : String, &block : ->) : Action
        action = add text
        action.on(::Crysterm::Event::Triggered) { block.call }
        action
      end

      # Creates a submenu action labeled *text* holding *actions*, appends it, and
      # returns it (Qt's `QMenu#addMenu`).
      def add_menu(text : String, actions : Array(Action)) : Action
        action = Action.new text
        action.menu = actions
        self << action
        action
      end

      # Appends a non-selectable separator rule (Qt's `QMenu#addSeparator`).
      def add_separator
        sep = Action.separator
        @actions << sep
        sep.associate self
        sync_items
        self
      end

      # Removes *action* from the menu. `#unwatch_action` (from
      # `Mixin::ActionWatcher`) removes its `Changed` handler and dissociates it.
      def >>(action : Action)
        if @actions.delete action
          unwatch_action action
          sync_items
        end
        self
      end

      # Shows this menu as a floating context menu at absolute (*x*, *y*), sized
      # to its content, focused, and dismissed on an outside click, after a leaf
      # action fires, or on Escape (Qt's `QMenu#popup`/`#exec`). The menu must be
      # on a window (created with `parent:`, or `window:` — `#popup` appends a
      # `window:`-only menu into the window's children so it actually renders).
      #
      # ```
      # menu = Widget::Menu.new parent: window, style: Style.new(border: true)
      # menu.add("Copy") { copy }
      # menu.add("Paste") { paste }
      # menu.popup e.x, e.y # e.g. from a right-click handler
      # ```
      def popup(x : Int32, y : Int32) : self
        @popup_mode = true
        # A (re)opened menu starts with no row highlighted — it's transient
        # interaction state, not carried across opens.
        @show_highlight = false
        # A menu created with only `window:` (not `parent:`) sets `@window` but is
        # not in the window's `children`, so `front!`/`set_index` find no index and
        # the menu never renders — while `popup` still opens a modal grab. Attach it
        # to the window's children when it isn't in the tree so it actually paints.
        window.append self unless @parent || window.children.includes?(self)
        fit_to_content
        # Open at the cursor, clamped on-window. `Overlay.place_child` owns the
        # clamp and the single absolute→window-local inset conversion (a
        # window-appended menu's `left`/`top` are relative to the window content
        # origin, so a padded window would otherwise shift it by the inset).
        Overlay.place_child(self, {x, y, 0, 0}, {awidth_hint, height.as?(Int) || 1},
          [Overlay::Side::At], point: {x, y})
        show
        front!
        focus

        # Modal grab (suppress hover/clicks outside the menu chain) + dismiss on a
        # press outside the *grab region* (not merely outside the submenu chain):
        # for a `MenuBar` the region also covers the bar's title strip, so clicking
        # the open menu's own title is "inside" and doesn't auto-close here,
        # letting the title's own toggle handler close it cleanly instead of
        # fighting an immediate reopen. Both live in one session bound to the
        # current window (guarded so a re-`popup` while open is a no-op).
        unless @popup_session
          s = ::Crysterm::Overlay::DismissSession.new(
            window, grab_owner: self,
            inside: ->(px : Int32, py : Int32) { grab_contains?(px, py) }) { hide_popup }
          s.open
          @popup_session = s
        end

        request_render
        self
      end

      # :ditto: (Qt names the blocking form `exec`; here it is non-blocking, like
      # `#popup`, and you react via the actions' `Event::Triggered`).
      def exec(x : Int32, y : Int32) : self
        popup x, y
      end

      # Hides a menu shown via `#popup`, tearing down its submenu chain and the
      # outside-click watcher. No-op unless in popup mode.
      def hide_popup : Nil
        return unless @popup_mode
        @popup_mode = false
        close_submenu
        hide
        # Releases the modal grab and detaches the watcher via the session's
        # captured window (safe even if `window?` is already nil).
        @popup_session.try &.close
        @popup_session = nil
        request_render
      end

      # Configured width used for on-window clamping in `#popup` (the value just
      # assigned by `#fit_to_content`).
      private def awidth_hint : Int32
        (width.as?(Int) || 1)
      end

      # Whether this menu auto-fits its width to its content (a popup or submenu);
      # an embedded menu given an explicit width opts out, keeping it.
      @autosize = false

      # The width that fits the rows: the widest row text plus the menu's own
      # `iwidth` (border + padding) and any reserved scroll-bar column. The
      # padding (`Menu { padding: 0 1 }`) is the gap between text and side
      # borders; reserving it here (rather than insetting the text) lets
      # `#size_rows` lay rows across the content box with padding falling
      # outside. Bump the theme padding for a roomier menu.
      private def fit_width : Int32
        # Display width, not codepoint count: an icon glyph (`a.icon`) or CJK/
        # emoji label is wider than its `.size`, and undersizing here would clip
        # the label.
        w = ritems.max_of? { |r| str_width r } || (visible_actions.max_of? { |a| str_width a.text } || 8)
        # A scrolling menu (e.g. a `Calendar`'s ±100 year list capped by
        # `#max_visible_rows`) reserves a right-edge column for the vertical
        # scroll bar. Without accounting for it here the widest row is one column
        # too wide for the drawable area, and `#size_rows` word-wraps it onto a
        # clipped second line — the row renders blank (only the gutter shows).
        w + iwidth + content_margin_x
      end

      # The height that fits the rows: one row per visible action plus the menu's
      # own `iheight` (top/bottom border + vertical padding). Derived from
      # `iheight` rather than a hardcoded `+ 2` so a borderless theme (e.g.
      # qdarkstyle's `QMenu { border: 0px }`) doesn't leave blank rows.
      private def fit_height : Int32
        rows = visible_actions.size
        if mv = @max_visible_rows
          rows = Math.min(rows, mv)
        end
        rows + iheight
      end

      # Sizes a popup/submenu to fit its content. Marks the menu auto-sizing so
      # `#autosize` keeps the box correct after the cascade resolves the real box
      # model (this runs pre-cascade for a freshly-opened submenu). Protected so
      # `#open_submenu` can size a child the same way `#popup` sizes a top-level.
      protected def fit_to_content : Nil
        @autosize = true
        self.width = fit_width
        self.height = fit_height
      end

      # Re-fits an auto-sized menu's box at render, once the cascade has set the
      # real box model (row padding, border/padding in `iwidth`/`iheight`).
      # `#fit_to_content` runs before that for a submenu, so it can miss the
      # resolved box model; this corrects both dimensions, growing rightward/down
      # from a fixed top-left anchor. No-op for an explicitly-sized embedded menu.
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
        # `content_width`, not `awidth - iwidth`: a scrolling menu reserves a
        # right-edge scroll-bar column (`content_margin_x`), so laying rows to the
        # full inner width would size them one column too wide, wrapping the text
        # onto a clipped second line (the year-dropdown "invisible rows" bug).
        inner = content_width
        return if inner < 1
        acts = @visible_actions
        return unless acts.size == @items.size
        # Nothing to re-lay unless the width changed or the rows were rebuilt
        # (`#sync_items`). The per-row content is a pure function of `inner` and
        # the cached `@row_lefts`/`@row_rights`, so an unchanged frame would
        # rebuild identical strings only for `set_content` to no-op them.
        return if inner == @last_laid_inner && !@rows_dirty
        lefts = @row_lefts
        rights = @row_rights
        @items.each_with_index do |it, i|
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
      # style, in place, before rows lay out (`super`). A row's content box then
      # spans its full width, so text — the `[x] ` prefix, label, right-aligned
      # shortcut/▶ — sits flush against the borders. Honoring the theme's pixel
      # padding here would inset the text instead; those columns are realized by
      # row text, not literal padding. Colors (`background`, `:selected`) stay.
      private def strip_item_box_model : Nil
        @items.each do |it|
          next if @separator_items.includes? it
          strip_box_model it.styles.normal
          strip_box_model it.styles.selected if it.styles.own_selected?
        end
      end

      private def strip_box_model(st : Style) : Nil
        st.padding = Padding.new(0) if st.padding.any?
        st.border = false if st.border.any?
      end

      # Stretches each separator's `─` rule across the menu's full inner width,
      # sized at render because that's the first point the final width is known.
      # A separator carries no item padding (not tagged `Item`), so it spans the
      # whole content area and, via `#dock_rows`, joins the borders as `├────┤`.
      # Guarded so content is only rewritten when width actually changed.
      private def size_separators : Nil
        return if @separator_items.empty?
        inner = awidth - iwidth
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
      # glyphs — the rows are rebuilt (a glyph change is a layout-affecting
      # event: column widths move; see GLYPHS.md §4). Builds on the shared
      # `WidgetContent#glyph_key` base triple (`{glyphs, glyph_tier,
      # Glyphs.generation}`), folding in the two sub-style glyphs the rows also
      # bake in (submenu-arrow indicator, separator rule).
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
        sync_items if @_glyph_key != row_glyph_key
      end

      # The currently highlighted action, or `nil` when the menu is empty.
      def selected_action : Action?
        visible_actions[selected]?
      end

      # Activates the highlighted action (as if Enter were pressed on it).
      def activate_selected
        activate_index selected
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
        # Only themed menus reach past the early return (a floor menu has no
        # surface `bg`), and themed items carry a stable per-state `Style` object
        # across frames — so an identity-keyed cache holds one surfaced copy per
        # row and reuses it every frame instead of dup-ing per row per frame. A
        # changed surface `bg` (or a cascade, which mints new item styles) drops
        # the stale entries.
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
      # carries the divider color in `background-color`, which becomes the
      # line's foreground when set; otherwise the menu's own foreground draws
      # it. Keeping the menu's background integrates the separator with the
      # surrounding frame. Border dropped (menu draws the frame), mirroring
      # `#item_render_style`.
      private def separator_render_style : Style
        sep = style.separator
        bg = style.bg
        # Reuse the derived line style while its inputs are unchanged — the source
        # `style.separator` object (replaced on cascade) and the menu surface
        # `bg`. Rebuilt only when one of those changes, instead of dup-ing per
        # separator per frame.
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
      # press should reveal the highlight). Mirrors the keys
      # `Mixin::ItemView#on_keypress` acts on, plus vi aliases when `#vi?`.
      private def selection_key?(e) : Bool
        # The vertical-navigation keys (Up/Down/paging/Home-End + vi j/k/g/G) are
        # classified once in `Mixin::NavKeys`; only vi H/M/L (top/middle/bottom of
        # viewport, handled inline in `ItemView#on_keypress`) fall outside it.
        !nav_intent(e).none? || (@vi && {'H', 'M', 'L'}.includes?(e.char))
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
        selekt i
        if act.enabled && act.menu?
          open_submenu act unless @submenu_open && @submenu_action == act
        end
      end

      # The visible actions, in display order. Cached: rebuilt only in
      # `#sync_items` (structural / visibility / label change), never per frame —
      # `#render` reads it through `#fit_width`/`#fit_height`/`#size_rows` every
      # frame. Callers must treat the returned array as read-only.
      private def visible_actions : Array(Action)
        @visible_actions
      end

      # The left (checkbox slot + label) and right (shortcut / ▶) text columns
      # for each visible action; separators get empty entries. The check
      # column is *measured* (GLYPHS.md §4): its width is the widest state's
      # composed `[x]` marker plus a gap, shared by every row so labels start
      # at a consistent column — and it vanishes entirely when no item is
      # checkable. Measured here, re-laid-out by `#sync_items`/`#size_rows`.
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
        # Refresh the cached visible-action snapshot and its per-row text columns
        # here (the single structural-change point), so the per-frame render path
        # reads them without recomputing. Mark the row layout dirty so the next
        # `#size_rows` re-lays even at an unchanged width. Stamp the glyph key
        # so `#refresh_glyphs` knows the rows reflect the current resolution.
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

        set_items rows

        # Rebuild the separator-row lookup from the just-built rows. `set_items`
        # leaves `@items[i]` corresponding to `acts[i]`, so a separator action's
        # row is the same-index item. Non-separator rows are tagged with the
        # `Item` CSS class so they're styled as the menu's `::item` sub-control
        # (Qt's rows aren't independent widgets but the menu's `::item`, which
        # inherits the menu surface and takes its highlight from
        # `QMenu::item:selected`). Without this, rows fall through to generic
        # `QWidget` rules and mismatch the frame.
        @separator_items = Set(Widget).new
        @items.each_with_index do |itm, i|
          if (a = acts[i]?) && a.separator?
            @separator_items << itm
          else
            itm.add_css_class "Item"
          end
        end
      end

      # Skips over separator rows so the highlight never rests on one. The
      # direction is inferred from whether the requested index is above or below
      # the current selection.
      def selekt(index : Int)
        # `selekt` does *not* enable `@show_highlight` — that's driven only by
        # user interaction (`#hover_item` / a selection key in `#on_keypress`),
        # so a programmatic selection never lights up a row on its own.
        acts = visible_actions
        unless acts.empty?
          dir = index >= selected ? 1 : -1
          index = skip_separators index, dir, acts
        end
        super index

        # Moving the highlight onto a different item closes a submenu anchored to
        # the previous one (clicking/selecting elsewhere dismisses the open menu).
        if @submenu_open && selected_action != @submenu_action
          close_submenu
        end
      end

      # A click lands on a *raw* row index (`Mixin::ItemView#create_item`), so a
      # click on a separator row would call `enter_selected(i)` → `selekt` (which
      # `#skip_separators` off the divider onto a neighbor) → `ActionItem` for
      # that neighbor → `activate_index`, silently firing the adjacent command.
      # Ignore activation when the clicked row is itself a separator; keyboard
      # activation is unaffected (its `selected` never rests on a separator).
      def enter_selected(i)
        return if @items[i]?.try { |it| @separator_items.includes? it }
        super
      end

      private def skip_separators(index : Int, dir : Int, acts : Array(Action)) : Int32
        n = acts.size
        return index.to_i if n == 0
        # Route through the shared `Mixin::ActionBar.nearest_selectable`: step in
        # `dir` over separators, rescanning the opposite way at a boundary so the
        # highlight never rests on a separator (`activate_index` refuses to fire
        # one). `nil` means an all-separator list — a degenerate menu with no real
        # rows — so fall back to the clamped index (still a separator, still
        # unfireable, but a valid in-range index for `#selekt`'s `super`).
        Mixin::ActionBar.nearest_selectable(n, index.to_i, dir) { |i| acts[i].separator? } || index.clamp(0, n - 1).to_i
      end

      private def activate_index(index : Int32)
        action = visible_actions[index]?
        return unless action
        return if action.separator?
        return unless action.enabled

        # A submenu item opens its child menu instead of firing — or, if already
        # open, toggles it closed (a second click/Enter closes it).
        if action.menu?
          if @submenu_open && @submenu_action == action
            close_submenu
          else
            open_submenu action
          end
          return
        end

        # `#activate` flips a checkable action's state before firing (emitting
        # `Event::Toggled`/`Event::Changed`, turned by `watch_action` into a
        # marker redraw) and carries the new state on `Event::Triggered`.
        action.activate

        # A leaf fired from within a submenu closes the whole chain back to the
        # top-level menu; fired directly on a top-level popup dismisses it.
        if parent_menu
          close_chain
        else
          hide_popup
        end
      end

      def on_keypress(e)
        # A menu opens with no row highlighted; the first selection-moving key —
        # or Enter — *reveals* the highlight on the current item rather than
        # moving/activating it. Without gating Enter here it would fall through to
        # `super` (`enter_selected` -> `activate_index 0`) and fire the first
        # action though no row was ever shown highlighted, contradicting the
        # documented "no highlight until interaction" model. Subsequent keys move
        # /activate normally via `super`.
        if !@show_highlight && (selection_key?(e) || e.key == ::Tput::Key::Enter)
          @show_highlight = true
          request_render
          e.accept
          return
        end

        # Right opens the highlighted item's submenu; Left/Escape closes this one
        # and returns focus to its parent. Handled before `super` so a submenu's
        # Escape doesn't fall through to the item view's cancel path.
        if e.key == ::Tput::Key::Right
          act = selected_action
          if act && act.menu?
            open_submenu act
            e.accept
            return
          elsif (nav = @on_navigate) && parent_menu.nil?
            # A top-level menu with no submenu to enter hands Right to its owner
            # (e.g. `MenuBar` moves to the next top-level menu).
            nav.call 1
            e.accept
            return
          end
        elsif e.key == ::Tput::Key::Left
          return if dismiss_to_parent_menu e
          if (nav = @on_navigate) && @submenu_open.nil?
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
          # rather than letting `super` fire a `CancelItem` on the unhighlighted
          # item 0 (same "no highlight until interaction" model as above).
          if !@show_highlight
            e.accept
            return
          end
        elsif e.key == ::Tput::Key::Up || e.key == ::Tput::Key::Down
          # Moving the highlight away closes any submenu anchored to the old row.
          close_submenu if @submenu_open
        end

        super
      end

      # Escape (and any cancel gesture) must not fire the highlighted action.
      # `Mixin::ItemView#cancel_selected` emits BOTH `ActionItem` and `CancelItem`,
      # and this menu treats `ActionItem` as activation (the handler wired in
      # `#initialize` calls `activate_index`), so the inherited cancel path would
      # run the highlighted — possibly destructive — action. Emit only `CancelItem`
      # (mirroring `ComboBox::Popup#cancel_selected`), and reset the revealed
      # highlight / open submenu ourselves since `#hide_popup` no-ops for an
      # embedded menu.
      def cancel_selected
        # See `Mixin::ItemView#cancel_selected`: guard against `IndexError` on an
        # empty list.
        return if @items.empty?
        close_submenu if @submenu_open
        @show_highlight = false
        emit ::Crysterm::Event::CancelItem, items[selected], selected
        request_render
      end

      # When this menu is a submenu, closes it via its parent and accepts *e*,
      # returning `true` (the caller then returns). A no-op returning `false` for
      # a top-level menu. Shared by the Left and Escape keys, which dismiss a
      # submenu back to its parent identically.
      private def dismiss_to_parent_menu(e) : Bool
        if pm = parent_menu
          pm.close_submenu
          e.accept
          return true
        end
        false
      end

      # Opens *action*'s submenu as a nested `Menu` floated to the right of the
      # current row, and moves focus into it.
      private def open_submenu(action : Action)
        subs = action.menu
        return unless subs && !subs.empty?

        close_submenu # replace any already-open child

        # Inherit this menu's own (inline) style so the child is bordered/colored
        # identically *from its first frame* — relying on the theme alone left a
        # freshly-created child briefly unstyled until the next cascade, flashing
        # a borderless copy during rapid reopening. Falls back to the theme when
        # this menu has no inline style.
        child = Menu.new(window: window, style: css_inline_style.try(&.dup))
        subs.each { |a| child << a }
        child.parent_menu = self

        # Add to the tree and resolve its themed box model *now*, before sizing
        # or focusing. A submenu is created fresh on open, so its border/padding
        # come only from the cascade, which otherwise wouldn't run until the next
        # render. Without this, `#fit_to_content` would size against a borderless
        # `iheight == 0` box, scrolling the first rows out of view — the
        # deep-submenu "last entry invisible until you hover" bug.
        window.append child
        window.restyle_structural child
        window.apply_stylesheet

        # Size the child like a top-level popup (`#fit_to_content`), then float
        # it right of the selected row — flipping to the *left* of the parent
        # only when it can't fit on the right (a menu near the right edge).
        # `Overlay.place_child` owns the fit choice, the on-window clamp, and the
        # single absolute→window-local inset conversion. When the menu draws a
        # border, folding `-border` into the anchor width keeps the right-side
        # baseline on the parent's right border column (the shared-divider
        # overlap); a borderless theme sits flush. The vertical
        # offset uses `itop` (0 when borderless). Both `Right` and `Left` share
        # the same row `y`, so the flip decision is purely horizontal and any
        # vertical overflow is clamped on-window. Further gap comes from the
        # submenu's `style.margin` (`_get_coords` adds it), not a hardcoded offset.
        child.fit_to_content
        begin
          lp = last_rendered_position
          border = style.border.any? ? 1 : 0
          row_top = lp.yi + itop + (selected - @child_base)
          Overlay.place_child(child,
            {lp.xi, row_top, (lp.xl - lp.xi) - border, 1},
            {child.width.as?(Int) || 1, child.height.as?(Int) || 1},
            [Overlay::Side::Right, Overlay::Side::Left])
        rescue
          child.left = 0
          child.top = 0
        end

        child.front!
        child.focus
        @submenu_open = child
        @submenu_action = action
        @submenu_anchor = @items[selected]?

        # The top-level menu watches for a click anywhere outside the open chain
        # and dismisses the submenus. In popup mode the `#popup` watcher already
        # covers outside clicks, so don't install a second one.
        if parent_menu.nil? && @submenu_session.nil? && !@popup_mode
          # "Inside" = the open child chain, or the anchor row (which
          # `#activate_index` toggles itself). A press anywhere else dismisses
          # the submenu and drops the highlight. No grab here — an embedded menu
          # (not a `#popup`) stays non-modal; only the outside-click watcher runs.
          inside = ->(x : Int32, y : Int32) do
            (@submenu_open.try(&.in_chain?(x, y)) || false) ||
            (@submenu_anchor.try(&.contains_point?(x, y)) || false)
          end
          s = ::Crysterm::Overlay::DismissSession.new(
            window, grab_owner: nil, inside: inside) do
            close_submenu
            @show_highlight = false
            request_render
          end
          s.open
          @submenu_session = s
        end

        request_render
      end

      # Closes this menu's open child submenu (recursively), refocusing this menu
      # first so destroying the focused child doesn't trigger a focus rewind.
      def close_submenu : Nil
        if child = @submenu_open
          child.close_submenu
          @submenu_open = nil
          @submenu_action = nil
          @submenu_anchor = nil
          focus
          window?.try &.remove child
          child.destroy
          request_render
        end

        # Once the top-level menu has no submenu left, drop the click watcher.
        if parent_menu.nil?
          @submenu_session.try &.close
          @submenu_session = nil
        end
      end

      # Whether the point (*x*, *y*) falls on this menu or anywhere in its open
      # submenu chain.
      def in_chain?(x : Int32, y : Int32) : Bool
        return true if contains_point?(x, y)
        if child = @submenu_open
          return child.in_chain?(x, y)
        end
        false
      end

      # Closes every open submenu from the top-level menu down (used after a leaf
      # action fires inside a submenu).
      protected def close_chain : Nil
        root = self
        while pm = root.parent_menu
          root = pm
        end
        root.close_submenu
        root.hide_popup # no-op unless the root is a popup
      end

      def destroy
        hide_popup
        close_submenu
        # Drop every per-action `Changed` handler and association, so destroying
        # this menu (including submenus rebuilt on each open/close) doesn't leave
        # stale handlers running `sync_items`/`selekt`/`request_render` against a
        # destroyed widget, nor a dead `Menu` pinned in `action.associated_widgets`.
        # `#unwatch_action` (Mixin::ActionWatcher) offs the handler when watched
        # and dissociates every action — covering separators, which are
        # associated (`#add_separator`) but never watched.
        @actions.each { |a| unwatch_action a }
        @actions.clear
        super
      end
    end
  end
end
