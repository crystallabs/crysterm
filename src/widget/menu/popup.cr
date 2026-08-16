module Crysterm
  class Widget
    class Menu
      # === Popup / submenu session management ===
      #
      # Everything that opens, anchors, dismisses and tears down floating menu
      # sessions: `#popup` context menus (modal grab + click-away watcher) and
      # the `#open_submenu`/`#close_submenu` chain. Split out of `menu.cr`
      # following the `text_edit.cr`/`text_edit/editing.cr` precedent.

      # The menu this one is a submenu of (`nil` for a top-level menu). Set when a
      # submenu is opened; used to route Left/Escape back to the parent.
      property parent_menu : Menu?

      # Extra region counted as "inside" for the modal input-grab (see
      # `Widget#grab_contains?`), on top of this menu's own submenu chain. A
      # `Widget::MenuBar` sets it to its own strip so hovering the bar's titles
      # still switches menus while one is open. Assigned through the public block
      # form `#treat_as_inside`; the raw setter is protected.
      getter grab_region : Proc(Int32, Int32, Bool)?
      protected setter grab_region

      # Marks *block* as an extra region counted as "inside" this menu's modal
      # grab, on top of its own submenu chain — so a press there (e.g. the owning
      # `MenuBar`'s title strip, a `ToolButton`, a `Calendar`'s nav bar) is *not*
      # read as a click-away that auto-dismisses the menu. A readable alias for
      # assigning the raw `#grab_region` proc.
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

      # Whether this menu is being shown as a floating context menu (see
      # `#popup`), so it dismisses itself on outside click / after a leaf fires.
      @popup_mode = false

      # Shows this menu as a floating context menu at absolute (*x*, *y*), sized
      # to its content, focused, and dismissed on an outside click, after a leaf
      # action fires, or on Escape (Qt's `QMenu#popup`/`#exec`). The menu must be
      # on a window (created with `parent:`, or `window:` — `#popup` appends a
      # `window:`-only menu into the window's children so it actually renders).
      #
      # ```
      # menu = Widget::Menu.new parent: window, style: Style.new(border: true)
      # menu.add_action("Copy") { copy }
      # menu.add_action("Paste") { paste }
      # menu.popup e.x, e.y # e.g. from a right-click handler
      # ```
      def popup(x : Int32, y : Int32) : self
        # Qt's `QMenu#aboutToShow`: fires before anything is laid out or shown, so
        # a handler can still populate/update the menu and have this very `popup`
        # size itself to the new rows.
        emit ::Crysterm::Event::AboutToShow

        @popup_mode = true
        # A (re)opened menu starts with no row highlighted — it's transient
        # interaction state, not carried across opens.
        @show_highlight = false
        # A menu created with only `window:` (not `parent:`) sets `@window` but is
        # not in the window's `children`, so `to_front`/`stack_index=` find no index
        # and it never renders, even though `popup` opens a modal grab.
        window.append self unless @parent || window.children.includes?(self)
        fit_to_content
        # Open at the cursor, clamped on-window. `Overlay.place_child` owns the
        # clamp and the single absolute→window-local inset conversion: a
        # window-appended menu's `left`/`top` are relative to the window content
        # origin, so a padded window would otherwise shift it by the inset.
        Overlay.place_child(self, {x, y, 0, 0}, {awidth_hint, height_spec.as?(Int) || 1},
          [Overlay::Side::At], point: {x, y})
        show
        to_front
        focus

        # Modal grab (suppress hover/clicks outside the menu chain) + dismiss on a
        # press outside the *grab region*, not merely outside the submenu chain:
        # for a `MenuBar` the region also covers the bar's title strip, so
        # clicking the open menu's own title is "inside" and its own toggle
        # handler closes it, rather than fighting an immediate reopen. Guarded so
        # a re-`popup` while open is a no-op.
        unless @popup_session
          s = ::Crysterm::Overlay::DismissSession.new(
            window, grab_owner: self,
            inside: ->(px : Int32, py : Int32) { grab_contains?(px, py) }) { hide_popup }
          s.open
          @popup_session = s
        end

        update!
        self
      end

      # NOTE: there is deliberately no `#exec`. Qt's `QMenu#exec` *blocks* and
      # returns the chosen `QAction` — that is its whole reason to exist next to
      # `popup()`, and blocking has no place in an async terminal toolkit's event
      # loop. Use `#popup` plus the actions' `Event::Triggered`.

      # Hides a menu shown via `#popup`, tearing down its submenu chain and the
      # outside-click watcher. No-op unless in popup mode.
      def hide_popup : Nil
        return unless @popup_mode
        # Qt's `QMenu#aboutToHide`: fires while the menu is still up, and only on
        # a real dismissal (the guard above already returned for a menu that
        # isn't popped up).
        emit ::Crysterm::Event::AboutToHide
        @popup_mode = false
        close_submenu
        hide
        # Releases the modal grab and detaches the watcher via the session's
        # captured window (safe even if `window?` is already nil).
        @popup_session.try &.close
        @popup_session = nil
        update!
      end

      # Configured width used for on-window clamping in `#popup` (the value just
      # assigned by `#fit_to_content`).
      private def awidth_hint : Int32
        (width_spec.as?(Int) || 1)
      end

      private def activate_index(index : Int32)
        action = visible_actions[index]?
        return unless action
        return if action.separator?
        return unless action.enabled?

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
        # marker redraw) and carries the new state on `Event::Triggered` —
        # except re-selecting the checked member of an exclusive `ActionGroup`,
        # which `#activate` keeps checked (Qt semantics).
        action.trigger

        # A leaf fired from within a submenu closes the whole chain back to the
        # top-level menu; fired directly on a top-level popup dismisses it.
        if parent_menu
          close_chain
        else
          hide_popup
        end

        # The chain is gone *because an action fired* (unlike an Escape or
        # outside-click dismissal): let the chain owner react — a `MenuBar`
        # fully deactivates, handing focus back to the central area. Called
        # after the closes above, so the owner sees the final state (and any
        # focus already rewound out of the hidden menus).
        root_menu.chain_activated_handler.try &.call
      end

      # When this menu is a submenu, closes it via its parent and accepts *e*,
      # returning `true` (the caller then returns). A no-op returning `false` for
      # a top-level menu.
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
        # identically *from its first frame*: the theme alone leaves a
        # freshly-created child unstyled until the next cascade, flashing a
        # borderless copy during rapid reopening. Falls back to the theme when
        # this menu has no inline style.
        child = Menu.new(window: window, style: inline_style.try(&.dup))
        # One row rebuild for the whole submenu, not one per action: this runs on
        # *every* open, so per-add `#sync_items` would make opening O(A²).
        child.batch_update { subs.each { |a| child << a } }
        child.parent_menu = self

        # Add to the tree and resolve its themed box model *now*, before sizing
        # or focusing. A submenu is created fresh on open, so its border/padding
        # come only from the cascade, which otherwise wouldn't run until the next
        # render — leaving `#fit_to_content` to size against a borderless
        # `ivertical == 0` box and scroll the first rows out of view.
        window.append child
        window.restyle_structural child
        window.apply_stylesheet

        # Size the child like a top-level popup, then float it right of the
        # selected row — flipping to the *left* of the parent only when it can't
        # fit on the right. `Overlay.place_child` owns the fit choice, the
        # on-window clamp, and the absolute→window-local inset conversion. When
        # the menu draws a border, folding `-border` into the anchor width keeps
        # the right-side baseline on the parent's right border column (the
        # shared-divider overlap); a borderless theme sits flush. Both `Right` and
        # `Left` share the same row `y`, so the flip is purely horizontal and
        # vertical overflow is clamped on-window. Further gap comes from the
        # submenu's `style.margin`, not a hardcoded offset.
        child.fit_to_content
        begin
          lp = last_rendered_position
          border = style.border.any? ? 1 : 0
          row_top = lp.yi + itop + (current_index - @child_base)
          Overlay.place_child(child,
            {lp.xi, row_top, (lp.xl - lp.xi) - border, 1},
            {child.width_spec.as?(Int) || 1, child.height_spec.as?(Int) || 1},
            [Overlay::Side::Right, Overlay::Side::Left])
        rescue
          child.left = 0
          child.top = 0
        end

        child.to_front
        child.focus
        @submenu_open = child
        @submenu_action = action
        @submenu_anchor = @item_boxes[current_index]?

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
            update!
          end
          s.open
          @submenu_session = s
        end

        update!
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
          update!
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

      # The top-level menu of this submenu chain (`self` when not a submenu).
      protected def root_menu : Menu
        root = self
        while pm = root.parent_menu
          root = pm
        end
        root
      end

      # Closes every open submenu from the top-level menu down (used after a leaf
      # action fires inside a submenu).
      protected def close_chain : Nil
        root = root_menu
        root.close_submenu
        root.hide_popup # no-op unless the root is a popup
      end
    end
  end
end
