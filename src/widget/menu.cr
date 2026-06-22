require "../action"

module Crysterm
  class Widget
    # A vertical menu of `Action`s, built on `List`.
    #
    # The (visible) actions are shown as selectable rows; arrow keys (and, with
    # `vi: true`, `j`/`k`) navigate, and Enter — or a click on the highlighted
    # row — activates the selected action. Activating emits the action's
    # `Event::Triggered`, received by any listener attached via
    # `action.on(Crysterm::Event::Triggered) { ... }`. Disabled actions are
    # listed but not activated.
    #
    # ```
    # menu = Widget::Menu.new parent: screen
    # quit = Action.new "Quit"
    # quit.on(Crysterm::Event::Triggered) { exit }
    # menu << quit
    # menu.focus
    # ```
    class Menu < List
      # Optional title, shown as the widget's label.
      property title : String = ""

      # The actions in this menu, in display order.
      property actions = [] of Action

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

      # Screen-level click watcher installed (on the top-level menu only) while a
      # submenu is open, to dismiss the chain when the user clicks away — e.g.
      # switching tabs.
      @ev_outside : Crysterm::Event::Mouse::Wrapper?

      # Screen-level click watcher installed while shown as a `#popup` context
      # menu, to dismiss the whole popup when the user clicks outside it.
      @ev_popup : Crysterm::Event::Mouse::Wrapper?

      def initialize(title = "", keys = nil, **widget)
        # `keys` is absorbed: `List` always enables key handling.
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

      # Whether this menu is being shown as a floating context menu (see
      # `#popup`), so it dismisses itself on outside click / after a leaf fires.
      @popup_mode = false

      # Adds *action* to the menu (no-op if already present).
      def <<(action : Action)
        unless @actions.includes? action
          @actions << action
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

        @ev_popup ||= screen.on(Crysterm::Event::Mouse) do |e|
          hide_popup if e.action.down? && !in_chain?(e.x, e.y)
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

      # Sizes the menu to its rendered rows plus border.
      private def fit_to_content : Nil
        w = ritems.max_of?(&.size) || (visible_actions.max_of? { |a| a.text.size } || 8)
        self.width = w + 2
        self.height = visible_actions.size + 2
      end

      # The currently highlighted action, or `nil` when the menu is empty.
      def selected_action : Action?
        visible_actions[selected]?
      end

      # Activates the highlighted action (as if Enter were pressed on it).
      def activate_selected
        activate_index selected
      end

      # Pointer moved onto row *i* (`List#hover_item` override, active because
      # menus set `#hover_select?`). Moves the highlight there — which closes any
      # submenu anchored elsewhere — and, if the row opens a submenu, opens it.
      # Separators are skipped; disabled rows highlight but don't open.
      def hover_item(i : Int)
        act = visible_actions[i]?
        return unless act
        return if act.separator?

        selekt i
        if act.enabled && act.submenu?
          open_submenu act unless @submenu_open && @submenu_action == act
        end
      end

      private def visible_actions : Array(Action)
        @actions.select &.visible?
      end

      # Rebuilds the list rows from the visible actions, drawing a `[x]`/`[ ]`
      # marker for checkable actions and a right-aligned shortcut column, and
      # rendering separators as a horizontal rule.
      private def sync_items
        acts = visible_actions
        any_checkable = acts.any? &.checkable?

        lefts = acts.map do |a|
          next "" if a.separator?
          prefix = if a.checkable?
                     a.checked? ? "[x] " : "[ ] "
                   elsif any_checkable
                     "    "
                   else
                     ""
                   end
          "#{prefix}#{a.text}"
        end
        rights = acts.map do |a|
          next "" if a.separator?
          next "▶" if a.submenu?
          a.shortcut.try(&.to_s) || ""
        end

        maxleft = lefts.max_of?(&.size) || 0
        maxright = rights.max_of?(&.size) || 0
        total = maxleft + (maxright > 0 ? 2 + maxright : 0)

        rows = acts.map_with_index do |a, i|
          if a.separator?
            "─" * Math.max(1, total)
          else
            row = lefts[i].ljust(maxleft)
            row += "  " + rights[i].rjust(maxright) if maxright > 0
            row
          end
        end

        set_items rows
      end

      # Skips over separator rows so the highlight never rests on one. The
      # direction is inferred from whether the requested index is above or below
      # the current selection.
      def selekt(index : Int)
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

        # Toggle a checkable action's state and redraw its marker before firing.
        if action.checkable?
          action.checked = !action.checked?
          sel = selected
          sync_items
          selekt sel
          request_render
        end

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
        # Right opens the highlighted item's submenu; Left/Escape closes this
        # submenu and returns focus to its parent. Handled before `super` so a
        # submenu's Escape doesn't fall through to `List`'s cancel path.
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
          if pm = parent_menu
            pm.close_submenu
            e.accept
            return
          elsif (nav = @on_navigate) && @submenu_open.nil?
            nav.call -1
            e.accept
            return
          end
        elsif e.key == ::Tput::Key::Escape
          if pm = parent_menu
            pm.close_submenu
            e.accept
            return
          elsif @popup_mode
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

      # Opens *action*'s submenu as a nested `Menu` floated to the right of the
      # current row, and moves focus into it.
      private def open_submenu(action : Action)
        subs = action.submenu
        return unless subs && !subs.empty?

        close_submenu # replace any already-open child

        child = Menu.new(
          screen: screen,
          style: Style.new(border: true),
        )
        subs.each { |a| child << a }
        child.parent_menu = self

        # Size to the content and float to the right of the selected row.
        child.width = (subs.max_of? { |a| a.text.size } || 8) + 6
        child.height = subs.size + 2
        begin
          lp = last_rendered_position
          child.left = lp.xl
          child.top = lp.yi + itop + (selected - @child_base)
        rescue
          child.left = 0
          child.top = 0
        end

        screen.append child
        child.front!
        child.focus
        @submenu_open = child
        @submenu_action = action

        # The top-level menu watches for a click anywhere outside the open chain
        # (a different tab, another widget, …) and dismisses the submenus. In
        # popup mode the `#popup` watcher already covers outside clicks (and
        # dismisses the whole popup), so don't install a second one.
        if parent_menu.nil? && @ev_outside.nil? && !@popup_mode
          @ev_outside = screen.on(Crysterm::Event::Mouse) do |e|
            close_submenu if e.action.down? && !in_chain?(e.x, e.y)
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
