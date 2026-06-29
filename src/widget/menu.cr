require "./box"
require "../action"
require "../mixin/item_view"

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
    # `Box` (the `QWidget`-like base) and only *includes* `Mixin::ItemView` for
    # the item rows and navigation, rather than inheriting `List`. Its CSS
    # identity is therefore `Menu < Box < Widget`, matching Qt's hierarchy
    # (`QMenu < QWidget`): a theme's item-view rules — `QAbstractItemView {
    # background-color; alternate-background-color; … }` — don't bleed onto menus,
    # so the menu takes the window/`QMenu` surface like the other `QWidget`-derived
    # chrome (`QMenuBar`/`QStatusBar`). (`Tree`/`ListTable`/the combo `Popup` are
    # real `QAbstractItemView`s.)
    #
    # ```
    # menu = Widget::Menu.new parent: screen
    # quit = Action.new "Quit"
    # quit.on(Crysterm::Event::Triggered) { exit }
    # menu << quit
    # menu.focus
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Menu screenshot](../../examples/widget/menu/menu-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Menu < Box
      include Mixin::ItemView

      # Optional title, shown as the widget's label.
      property title : String = ""

      # The actions in this menu, in display order.
      property actions = [] of Action

      # Caps the auto-sized (popup/submenu) height to at most this many item rows,
      # scrolling the remainder rather than growing past it — mirrors
      # `ComboBox#max_visible`. `nil` (the default) fits every row. A long
      # navigation dropdown (e.g. a `Calendar`'s ±100 year list, far taller than
      # the screen) sets this so the popup stays on-screen and scrolls to its
      # selected entry instead of being clamped over the content behind it.
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
      # row highlighted (Qt-like): the highlight appears only once the user hovers
      # a row (`#hover_item`) or presses a selection key (`#on_keypress`), and is
      # cleared again when the menu is dismissed by an outside click. So an
      # untouched, freshly-opened menu shows no pre-selected entry.
      @show_highlight = false

      # The item boxes that render as separator rules, rebuilt once per
      # `#sync_items` (which already walks the visible actions). Lets
      # `#render_style_for` decide "is this row a separator?" with an O(1) set
      # lookup, instead of the per-row `@items.index` scan + fresh
      # `visible_actions` array it would otherwise do on every child every frame.
      @separator_items = Set(Widget).new

      # Screen-level click watcher installed (on the top-level menu only) while a
      # submenu is open, to dismiss the chain when the user clicks away — e.g.
      # switching tabs.
      @ev_outside : Crysterm::Event::Mouse::Wrapper?

      # Screen-level click watcher installed while shown as a `#popup` context
      # menu, to dismiss the whole popup when the user clicks outside it.
      @ev_popup : Crysterm::Event::Mouse::Wrapper?

      def initialize(title = "", keys = nil, **widget)
        # `keys` is absorbed: an item view always enables key handling.
        @title = title

        super **widget

        # Own our style: menus are independent (and frequently created from one
        # shared style, e.g. a menu bar's File/Edit/Help). Since per-widget
        # visibility is stored in `Style`, a *shared* style would couple their
        # show/hide — opening one would reveal them all. Dup so each menu (hence
        # each `#popup`) toggles only itself.
        @style = @style.try(&.dup)

        # Menus activate on a single click (open submenu / fire action), like a
        # real menu — not the list's two-click select-then-activate. They also
        # track the mouse: hovering a row selects it (see `#hover_item`).
        @activate_on_click = true
        @hover_select = true

        set_label @title unless @title.empty?
        sync_items

        # Enter (or a click on the already-selected row) emits `ActionItem`;
        # activate the corresponding action.
        on(::Crysterm::Event::ActionItem) { |e| activate_index e.index }
      end

      # A menu is an overlay: at the unstyled floor (no theme/CSS) it carries a
      # structural border so it separates from the content behind it. Any active
      # theme makes the menu `css_styled`, so it stays free to set any border —
      # including none (qdarkstyle's `QMenu { border: 0 }`); see
      # `Mixin::Style#floor_border?`.
      def floor_border? : Bool
        true
      end

      # Whether this menu is being shown as a floating context menu (see
      # `#popup`), so it dismisses itself on outside click / after a leaf fires.
      @popup_mode = false

      # Per-action `Event::Changed` handlers, so the menu can refresh when an
      # action's display state (checked, text, enabled, visibility) is changed
      # from the outside. Kept by action so the handler can be removed in `>>`.
      @action_changed = {} of Action => ::Proc(::Crysterm::Event::Changed, ::Nil)

      # Adds *action* to the menu (no-op if already present).
      def <<(action : Action)
        unless @actions.includes? action
          @actions << action
          watch_action action
          sync_items
        end
        self
      end

      # Re-render the menu whenever *action*'s display state changes, mirroring
      # how a Qt menu tracks its `QAction`s' `changed()` signal. Without this, an
      # external `action.checked = ...` (or `text=`, `enabled=`, `visible=`)
      # would not update the already-rendered rows.
      private def watch_action(action : Action) : Nil
        return if @action_changed.has_key? action
        handler = ->(_e : ::Crysterm::Event::Changed) do
          # Preserve the highlighted row across the rebuild (item count can shift
          # when visibility toggles), matching the in-menu activate path.
          sel = selected
          sync_items
          selekt sel
          request_render
          nil
        end
        action.on ::Crysterm::Event::Changed, handler
        @action_changed[action] = handler
      end

      private def unwatch_action(action : Action) : Nil
        if handler = @action_changed.delete action
          action.off ::Crysterm::Event::Changed, handler
        end
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
        action.submenu = actions
        self << action
        action
      end

      # Appends a non-selectable separator rule (Qt's `QMenu#addSeparator`).
      def add_separator
        @actions << Action.separator
        sync_items
        self
      end

      # Removes *action* from the menu.
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
      # on a screen (created with `screen:` / `parent:`).
      #
      # ```
      # menu = Widget::Menu.new screen: screen, style: Style.new(border: true)
      # menu.add("Copy") { copy }
      # menu.add("Paste") { paste }
      # menu.popup e.x, e.y # e.g. from a right-click handler
      # ```
      def popup(x : Int32, y : Int32) : self
        @popup_mode = true
        # A (re)opened menu starts with no row highlighted — the highlight is a
        # transient interaction state, not carried across opens. Without this a
        # menu reopened after a prior hover would come up pre-highlighted.
        @show_highlight = false
        fit_to_content
        sw = screen.awidth
        sh = screen.aheight
        # Keep the menu on-screen.
        self.left = x.clamp(0, Math.max(0, sw - (awidth_hint)))
        self.top = y.clamp(0, Math.max(0, sh - (height.as?(Int) || 1)))
        show
        front!
        focus
        screen.grab self # modal: suppress hover/clicks outside the menu chain

        # Dismiss on a press outside the *grab region* (not merely outside the
        # submenu chain): for a `MenuBar` the region also covers the bar's title
        # strip, so clicking the open menu's own title is "inside" and does not
        # auto-close here. That lets the title's toggle handler close it cleanly —
        # otherwise this watcher would hide the popup and the toggle would
        # immediately reopen it, so a second click never appeared to close.
        @ev_popup ||= screen.on_press_outside(->(px : Int32, py : Int32) { grab_contains?(px, py) }) { hide_popup }

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
        screen?.try &.ungrab self
        @ev_popup.try { |w| screen?.try &.off Crysterm::Event::Mouse, w }
        @ev_popup = nil
        request_render
      end

      # Configured width used for on-screen clamping in `#popup` (the value just
      # assigned by `#fit_to_content`).
      private def awidth_hint : Int32
        (width.as?(Int) || 1)
      end

      # Whether this menu auto-fits its width to its content (a popup or submenu);
      # an embedded menu given an explicit width opts out, keeping it.
      @autosize = false

      # The width that fits the rows: the widest row text plus the menu's own
      # `iwidth` — its border **and** padding. The padding (`Menu { padding: 0 1 }`)
      # is the single breathing source: a sane gap between the text and the side
      # borders. Reserving it here (rather than insetting the text) lets
      # `#size_rows` lay the rows out across the content box, with the padding
      # falling outside as that gap. Bump the theme padding for a roomier menu.
      private def fit_width : Int32
        w = ritems.max_of?(&.size) || (visible_actions.max_of?(&.text.size) || 8)
        w + iwidth
      end

      # The height that fits the rows: one row per visible action plus the menu's
      # own `iheight` — its top/bottom border **and** any vertical padding. Derived
      # from `iheight` rather than a hardcoded `+ 2` so a theme that draws no menu
      # border (e.g. qdarkstyle's `QMenu { border: 0px }`) doesn't leave blank rows
      # where the borders would have been — no assumption that a border exists.
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

      # Re-fits an auto-sized menu's box at render, now that the cascade has set
      # the real box model — the row `QMenu::item` padding (in `@item_box_w`, just
      # captured by `#strip_item_box_model`) and the menu's own border/padding (in
      # `iwidth`/`iheight`). `#fit_to_content` runs before that for a submenu, so
      # its width *and* height can miss the resolved box model (e.g. a border the
      # theme adds, or omits); this corrects both — the menu grows rightward/down,
      # its top-left anchor fixed. No-op for an explicitly-sized embedded menu.
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
        inner = awidth - iwidth
        return if inner < 1
        acts = visible_actions
        return unless acts.size == @items.size
        lefts, rights = row_columns(acts)
        @items.each_with_index do |it, i|
          next if @separator_items.includes? it
          l = lefts[i]
          r = rights[i]
          pad = inner - l.size - r.size
          content = pad >= 1 ? "#{l}#{" " * pad}#{r}" : "#{l}#{r}"[0, inner]
          it.set_content(content) unless it.content == content
        end
      end

      # Renders the menu, then docks its separator rules to the vertical borders
      # so each reads as `├────┤` rather than a detached dash. Reuses the screen's
      # border-docking component (`#dock_rows`), so it needs no global
      # `dock_borders`. Runs after `super` (which draws the border *and* the
      # separator-row items), re-applying the junctions each frame the border is
      # repainted.
      def render(with_children = true)
        strip_item_box_model
        autosize
        size_rows
        size_separators
        ret = super
        unless @separator_items.empty?
          rows = @separator_items.compact_map { |itm| itm.@lpos.try &.yi }
          dock_rows rows
        end
        ret
      end

      # Strips the `QMenu::item` `padding`/`border` from every row's computed
      # style, in place, before the rows lay out (`super`). A row's content box
      # then spans its full width, so its text — the `[x] ` checkable prefix, the
      # label, and the right-aligned shortcut/▶ — sits flush: prefix at the left
      # border, label after it, the ▶ at the right border. Honoring the theme's
      # pixel padding here instead would inset the text (pushing labels right and
      # leaving a gap after the ▶) — those columns are realized by the row text,
      # not by literal padding. Colors (`background`, `:selected`) are left intact.
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
      # sized here (at render) because that is the first point the final width is
      # known — it is grown by `#fit_to_content` to reserve the rows' `QMenu::item`
      # padding, which the rows are built before. A separator carries no item
      # padding (it is not tagged `Item`), so it spans the whole content area and,
      # via `#dock_rows`, joins the side borders as `├────┤`. Guarded so the
      # content is only rewritten when the width actually changed.
      private def size_separators : Nil
        return if @separator_items.empty?
        inner = awidth - iwidth
        return if inner < 1
        @separator_items.each do |it|
          it.set_content("─" * inner) unless it.content.size == inner
        end
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
        # `QMenu::separator`), regardless of highlight state — separators are
        # never selectable, so they never take the highlight. The separator rows
        # are precomputed in `#sync_items`, so this is an O(1) set lookup.
        if @separator_items.includes? item
          return separator_render_style
        end
        # Until the highlight is revealed (hover / first nav key), draw every row
        # in its *normal* look — but still via the per-item CSS style, so themed
        # colors apply. Falling back to a bare `item_render_style` here dropped the
        # cascaded styling and made a freshly-opened menu look disabled.
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

      # A `QMenu::item { background: transparent }` row (Qt's default — the item
      # shows the menu surface) resolves to *no* background; but a child widget
      # with no background paints the terminal default, not its parent's painted
      # surface. So fill an unset/transparent item background from the menu's own,
      # giving the Qt look (rows flush with the frame) without a per-theme hack.
      # The item's `padding`/`border` are *kept* — they're reserved in the menu's
      # width by `#fit_to_content` so the label still fits.
      private def item_on_surface(st : Style) : Style
        bg = st.bg
        return st unless (bg.nil? || bg == -1) && (surface = style.bg)
        out = st.dup
        out.bg = surface
        out
      end

      # The style for a separator row: the `─` rule (its content, built in
      # `#sync_items`) sits on the menu's own surface — not a filled band of the
      # divider color. Qt's `QMenu::separator` carries the divider color in its
      # `background-color`, so that becomes the *line* color (the rule's
      # foreground) when a rule set it; otherwise the menu's own foreground draws
      # the line. Keeping the menu's background lets the separator integrate with
      # the surrounding entries and the frame. The border is dropped (the menu
      # draws the frame), mirroring `#item_render_style`.
      private def separator_render_style : Style
        sep = style.separator
        line = sep.dup
        line.border = false
        bg = style.bg
        # A separator rule that set a (divider) background different from the menu
        # surface supplies the line color; otherwise fall back to the foreground.
        sep_bg = sep.bg
        line.fg = (sep_bg && sep_bg != bg) ? sep_bg : sep.fg
        line.bg = bg
        line
      end

      # Pointer moved onto row *i* (`Mixin::ItemView#hover_item` override, active because
      # menus set `#hover_select?`). Moves the highlight there — which closes any
      # submenu anchored elsewhere — and, if the row opens a submenu, opens it.
      # Separators are skipped; disabled rows highlight but don't open.
      # Whether *e* is a key that moves the list selection (so the first such
      # press should reveal the highlight). Mirrors the keys `Mixin::ItemView#on_keypress`
      # acts on, plus the vi aliases when `#vi?`.
      private def selection_key?(e) : Bool
        case e.key
        when ::Tput::Key::Up, ::Tput::Key::Down, ::Tput::Key::Home, ::Tput::Key::End,
             ::Tput::Key::PageUp, ::Tput::Key::PageDown, ::Tput::Key::CtrlU, ::Tput::Key::CtrlD
          true
        else
          @vi && {'j', 'k', 'g', 'G', 'H', 'M', 'L'}.includes?(e.char)
        end
      end

      def hover_item(i : Int)
        act = visible_actions[i]?
        return unless act
        return if act.separator?

        @show_highlight = true # hovering a row reveals (and moves) the highlight
        selekt i
        if act.enabled && act.submenu?
          open_submenu act unless @submenu_open && @submenu_action == act
        end
      end

      private def visible_actions : Array(Action)
        @actions.select &.visible?
      end

      # The left (checkbox slot + label) and right (shortcut / ▶) text columns for
      # each visible action; separators get empty entries. The **checkbox slot is
      # always reserved** — `[x] `/`[ ] ` for a checkable action, four blanks
      # otherwise — so labels start at a consistent column even in a menu with no
      # checkable items (Qt always reserves the check/icon gutter). The same
      # columns are measured by `#sync_items` and re-laid-out by `#size_rows`.
      private def row_columns(acts : Array(Action)) : {Array(String), Array(String)}
        lefts = acts.map do |a|
          next "" if a.separator?
          prefix = a.checkable? ? (a.checked? ? "[x] " : "[ ] ") : "    "
          "#{prefix}#{a.text}"
        end
        rights = acts.map do |a|
          next "" if a.separator?
          next "▶" if a.submenu?
          a.shortcut.try(&.to_s) || ""
        end
        {lefts, rights}
      end

      # Rebuilds the list rows from the visible actions. Each row's text holds the
      # full column layout — the checkbox slot + label, then the shortcut/▶ — and
      # `#size_rows` stretches it to the final width (label flush-left, shortcut/▶
      # flush-right) at render. Separators are a placeholder here, sized by
      # `#size_separators`.
      private def sync_items
        acts = visible_actions
        lefts, rights = row_columns(acts)

        rows = acts.map_with_index do |a, i|
          if a.separator?
            "─"
          else
            row = lefts[i]
            row += "  " + rights[i] unless rights[i].empty?
            row
          end
        end

        set_items rows

        # Rebuild the separator-row lookup from the just-built rows. `set_items`
        # left `@items[i]` corresponding to `acts[i]` (rows were built from
        # `acts` in order), so a separator action's row is the same-index item.
        # Each non-separator row is also tagged with the `Item` CSS class so it is
        # styled as the menu's `::item` sub-control — Qt's model: a `QMenu`'s rows
        # aren't independent widgets but the menu's `::item`, which inherits the
        # menu surface (`QMenu::item { background: transparent | <surface> }`) and
        # takes its highlight from `QMenu::item:selected`. Without this the row
        # `Box`es fall through to generic `QWidget` rules and mismatch the frame.
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
        # Note: `selekt` does *not* enable `@show_highlight` — that is driven only
        # by user interaction (`#hover_item` / a selection key in `#on_keypress`),
        # so a programmatic selection (the initial `selekt 0` when the first item
        # is added, an action-change refresh, …) never lights up a row on its own.
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

      private def skip_separators(index : Int, dir : Int, acts : Array(Action)) : Int32
        n = acts.size
        return index.to_i if n == 0
        i = index.clamp(0, n - 1)
        n.times do
          a = acts[i]?
          break unless a && a.separator?
          ni = i + dir
          break if ni < 0 || ni >= n
          i = ni
        end
        # Stepping in `dir` stops on a separator when it hits the array boundary
        # before reaching a real item — e.g. a leading separator skipped upward,
        # or a trailing one skipped downward. The highlight must never rest on a
        # separator (`activate_index` refuses to fire one, so the row would be a
        # dead selection), so fall back to scanning the opposite way for the
        # nearest selectable action.
        if acts[i]?.try &.separator?
          j = i
          while (j -= dir) >= 0 && j < n
            unless acts[j].separator?
              i = j
              break
            end
          end
        end
        i
      end

      private def activate_index(index : Int32)
        action = visible_actions[index]?
        return unless action
        return if action.separator?
        return unless action.enabled

        # A submenu item opens its child menu instead of firing — or, if that
        # same submenu is already open, toggles it closed (a second click/Enter on
        # an open menu closes it).
        if action.submenu?
          if @submenu_open && @submenu_action == action
            close_submenu
          else
            open_submenu action
          end
          return
        end

        # Toggle a checkable action's state before firing; the assignment emits
        # `Event::Changed`, which `watch_action` turns into a marker redraw.
        action.checked = !action.checked? if action.checkable?

        action.activate

        # After a leaf action runs from within a submenu, close the whole submenu
        # chain (back to the persistent top-level menu); a leaf fired directly on
        # a top-level popup dismisses the popup.
        if parent_menu
          close_chain
        else
          hide_popup
        end
      end

      def on_keypress(e)
        # A menu opens with no row highlighted; the first selection-moving key
        # *reveals* the highlight on the current item rather than moving it (like
        # pressing an arrow on a freshly-opened desktop menu). Subsequent keys
        # move it normally via `super`.
        if !@show_highlight && selection_key?(e)
          @show_highlight = true
          request_render
          e.accept
          return
        end

        # Right opens the highlighted item's submenu; Left/Escape closes this
        # submenu and returns focus to its parent. Handled before `super` so a
        # submenu's Escape doesn't fall through to the item view's cancel path.
        if e.key == ::Tput::Key::Right
          act = selected_action
          if act && act.submenu?
            open_submenu act
            e.accept
            return
          elsif (nav = @on_navigate) && parent_menu.nil?
            # A top-level menu with no submenu to enter hands Right to its owner
            # (e.g. a `MenuBar` moves to the next top-level menu).
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
        elsif e.key == ::Tput::Key::Up || e.key == ::Tput::Key::Down
          # Moving the highlight away closes any submenu anchored to the old row.
          close_submenu if @submenu_open
        end

        super
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
        subs = action.submenu
        return unless subs && !subs.empty?

        close_submenu # replace any already-open child

        # Inherit this menu's own (inline) style so the child is bordered/colored
        # identically *from its first frame*. Relying on the theme alone left a
        # freshly-created child briefly unstyled until the next cascade — which,
        # while the chain was being rapidly reopened, could flash a borderless
        # copy alongside the styled one. Falls back to the theme (`Menu { ... }`)
        # when this menu has no inline style.
        child = Menu.new(screen: screen, style: css_inline_style.try(&.dup))
        subs.each { |a| child << a }
        child.parent_menu = self

        # Add to the tree and resolve its themed box model *now*, before sizing or
        # focusing. A submenu is created fresh on open, so (unlike a top-level menu
        # built at startup and cascaded over earlier frames) its border/padding
        # come only from the cascade — which otherwise wouldn't run until the next
        # render. Without this, `#fit_to_content` would size against a borderless
        # `iheight == 0` box and the focus-time scroll math would run against that
        # too-short height, scrolling the first rows out of view: the deep-submenu
        # "last entry invisible until you hover" bug on bordered themes.
        screen.append child
        screen.restyle_structural child
        screen.apply_stylesheet

        # Size the child exactly like a top-level popup (`#fit_to_content`), so a
        # submenu gets the same column layout, breathing and padding. Then float it
        # to the right of the selected row. When the menu draws a border, the left
        # baseline is the parent's right *border column* (`lp.xl - 1`) so the
        # submenu's left border overlaps it (a shared divider, like a desktop
        # menu); a borderless theme (e.g. qdarkstyle) has no border to share, so
        # the child sits flush at the parent's right edge (`lp.xl`) rather than
        # biting a content column — no assumption that a border exists. The
        # vertical offset uses `itop` (0 when borderless) likewise. Any further gap
        # is driven purely by the submenu's `style.margin` (`_get_coords` adds
        # `margin.left`/`margin.top`), so a themed or explicit margin distances it
        # without any hardcoded offset.
        child.fit_to_content
        begin
          lp = last_rendered_position
          child.left = lp.xl - (style.border.any? ? 1 : 0)
          child.top = lp.yi + itop + (selected - @child_base)
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
        # (a different tab, another widget, …) and dismisses the submenus. In
        # popup mode the `#popup` watcher already covers outside clicks (and
        # dismisses the whole popup), so don't install a second one.
        if parent_menu.nil? && @ev_outside.nil? && !@popup_mode
          # "Inside" = the open child chain, or the anchor row (which
          # `#activate_index` toggles itself). A press anywhere else — another
          # row, the menu's own empty area, or right off the menu — dismisses the
          # submenu and drops the highlight, so no row is left looking selected.
          inside = ->(x : Int32, y : Int32) do
            (@submenu_open.try(&.in_chain?(x, y)) || false) ||
            (@submenu_anchor.try(&.contains_point?(x, y)) || false)
          end
          @ev_outside = screen.on_press_outside(inside) do
            close_submenu
            @show_highlight = false
            request_render
          end
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
          screen?.try &.remove child
          child.destroy
          request_render
        end

        # Once the top-level menu has no submenu left, drop the click watcher.
        if parent_menu.nil?
          @ev_outside.try { |w| screen?.try &.off Crysterm::Event::Mouse, w }
          @ev_outside = nil
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
        super
      end
    end
  end
end
