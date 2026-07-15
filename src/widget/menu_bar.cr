require "./box"
require "./menu"
require "../mixin/action_bar"

module Crysterm
  class Widget
    # Horizontal bar of pop-up menus, modeled after Qt's `QMenuBar`.
    #
    # Each title added with `#add_menu` drops a `Widget::Menu` when clicked (or
    # via Enter/Down/Space while the bar is focused). Once a menu is open, hovering
    # or arrowing with Left/Right onto another title switches to it (closing the
    # previous); the active title is highlighted, none when no menu is open.
    # Escape, an outside click, or activating a leaf closes the menu.
    #
    # Built on `Mixin::ActionBar` (layout, keyboard navigation, hotkeys) and
    # `Menu` (the pop-ups).
    #
    # ```
    # bar = Widget::MenuBar.new parent: window, top: 0, left: 0, width: "100%", height: 1
    # file = bar.add_menu "File"
    # file.add("New") { new_doc }
    # file.add("Open") { open_doc }
    # bar.add_menu "Edit", [cut_action, copy_action]
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![MenuBar screenshot](../../tests/widget/menu_bar/menu_bar.5s.apng)
    # <!-- /widget-examples:capture -->
    class MenuBar < Box
      include Mixin::ActionBar

      # The pop-up menus, parallel to the bar's commands/items.
      getter menus = [] of Menu

      # Style for the pop-up menus (defaults to a bordered box).
      property menu_style : Style?

      # Index of the currently open menu, or `nil` when none is open.
      getter open_index : Int32?

      def initialize(menu_style : Style? = nil, **listbar)
        @menu_style = menu_style

        # Always keyboard/mouse-driven, plain titles ("File", not ActionBar's default "1:File").
        super(**listbar.merge(keys: true))
        setup_action_bar mouse: true, auto_prefix: false
        # Titles pack flush (only trailing the last title); each keeps its own side padding.
        @item_gap = 0

        # Keep highlight on the open menu regardless of bar focus — the action bar
        # would otherwise re-light its own selected item.
        on(::Crysterm::Event::Focus) { sync_highlight }
        on(::Crysterm::Event::Blur) { sync_highlight }

        # Wire menu actions' keyboard accelerators to the window lifecycle, so e.g.
        # "Copy" (Ctrl+C) fires without opening the menu first (Qt's menu-action shortcuts).
        # On a cross-window reparent the pop-up menus (children of the *old*
        # window) migrate first, so they open on the window the bar now lives on.
        on(::Crysterm::Event::Attach) do
          rehome_menus
          install_menu_shortcuts
        end
        # Uninstall from the window carried on the event: `Widget#remove` nulls
        # `parent`/`window` before `Window#detach` emits `Event::Detach`, so
        # `window?` is already nil here — the previous window comes via the payload.
        on(::Crysterm::Event::Detach) { |e| uninstall_menu_shortcuts e.object.as?(::Crysterm::Window) }
      end

      # Adds a top-level menu titled *title* (optionally pre-filled with
      # *actions*) and returns the `Menu` so more can be added to it.
      def add_menu(title : String, actions : Array(Action) = [] of Action) : Menu
        # `parent: window` appends the pop-up to the render tree so it actually
        # draws (a bare `window:` would leave it visible-flagged but undrawn).
        # Border/look come from the theme (`Menu { ... }`) unless `@menu_style` is set.
        menu = Menu.new(parent: window, style: @menu_style)
        actions.each { |a| menu << a }
        # Bar is normally already attached here, so wire accelerators now;
        # `install_menu_shortcuts` re-covers them on a later re-attach.
        window?.try { |w| visit_actions(menu, &.install_shortcut(w, self)) }
        menu.hide
        menu.on_navigate = ->(dir : Int32) { switch_relative dir }
        # The bar's own strip counts as "inside" the open menu's modal grab, so
        # hovering another title still switches menus while one is open.
        menu.treat_as_inside { |x, y| grab_contains? x, y }
        menu.on(::Crysterm::Event::Hide) { on_menu_hidden menu }
        # Actions added *after* this call (`file.add action` on an attached bar)
        # must get their accelerators too: the menu emits `SetItems` on every
        # structural change (`Menu#<<`/`#remove_action`/`#add…` → `sync_items`), so re-run
        # the idempotent install then. Without this, a shortcut added post
        # `add_menu` stayed silently dead until a detach/re-attach. Scope the
        # (re)install to the changed menu — `SetItems` fires per-add while a bar
        # is built, so re-walking *every* menu's actions each time is ~O((M·A)²);
        # each other menu's shortcuts are already installed and the per-`Subscription`
        # registration is idempotent, so the final state is identical.
        menu.on(::Crysterm::Event::SetItems) { install_menu_shortcuts menu }
        # Close the menu when it loses focus to something outside the bar's world
        # (mouse-click dismissal is handled separately by `Menu#popup`'s
        # `on_press_outside`). Diving into a submenu or moving to the bar/another
        # menu is an internal move and is ignored.
        menu.on(::Crysterm::Event::Blur) { |e| on_menu_blur menu, e }

        index = @menus.size
        @menus << menu
        add_item(title) { toggle index } # action-bar command: click / Enter toggles it

        # Hover a different title (while a menu is open) to switch to it.
        if item = items[index]?
          item.on(::Crysterm::Event::MouseOver) do
            open index if @open_index && @open_index != index
          end
        end

        sync_highlight # clear the bar's auto-selection of the first item
        menu
      end

      # Installs every menu action's accelerator (descending into submenus).
      # Idempotent per window.
      private def install_menu_shortcuts : Nil
        w = window? || return
        @menus.each { |m| visit_actions(m, &.install_shortcut(w, self)) }
      end

      # :ditto: — for a single *menu* only. `Event::SetItems` fires per structural
      # change and knows which menu changed, so only its actions need re-covering.
      private def install_menu_shortcuts(menu : Menu) : Nil
        w = window? || return
        visit_actions(menu, &.install_shortcut(w, self))
      end

      # Withdraws every menu action's accelerator from *w* (the window the bar
      # is leaving, supplied via the `Detach` event payload).
      private def uninstall_menu_shortcuts(w : ::Crysterm::Window?) : Nil
        return unless w
        @menus.each { |m| visit_actions(m, &.uninstall_shortcut(w)) }
      end

      # Moves any pop-up menu still hosted on a previous window over to the
      # bar's current one (safe while closed — the menus are hidden window
      # children). Without this, a bar reparented cross-window opened its
      # menus (and took their modal grab) on the OLD window.
      private def rehome_menus : Nil
        w = window? || return
        @menus.each do |m|
          old = m.window?
          next if old.same?(w)
          old.try &.remove m
          w.append m
        end
      end

      # Yields every action in *menu*, recursing into submenu actions.
      private def visit_actions(menu : Menu, &block : Action ->) : Nil
        menu.actions.each { |a| visit_action a, block }
      end

      private def visit_action(action : Action, block : Action ->) : Nil
        block.call action
        action.menu.try &.each { |c| visit_action c, block }
      end

      # Opens menu *i* (closing any other), positioned under its title.
      def open(i : Int) : Nil
        return unless menu = @menus[i]?
        @menus.each_with_index { |m, j| m.hide_popup if j != i && m.visible? }
        @open_index = i = i.to_i
        # Move the bar's current item to match, so hover-switching also carries
        # the keyboard cursor. `select_index` re-imposes the open-menu highlight below.
        select_index i
        menu.popup title_x(i), menu_y
      end

      # Toggles menu *i*: opens it, or closes it (deselecting the title) if it is
      # already the open one — matching the click behavior of desktop menu bars.
      def toggle(i : Int) : Nil
        if @open_index == i.to_i
          close
        else
          open i
        end
      end

      # Closes the open menu, if any.
      def close : Nil
        @open_index.try { |i| @menus[i]?.try &.hide_popup }
      end

      def on_keypress(e)
        # Down/Space open the highlighted menu (Enter and Left/Right come from `Mixin::ActionBar`).
        if (e.key == ::Tput::Key::Down || e.char == ' ') && !@menus.empty?
          open selected
          e.accept
          return
        end
        super
      end

      # Switches to the menu *dir* away (wrapping), used by the open menu's
      # `Menu#on_navigate` for Left/Right.
      private def switch_relative(dir : Int32) : Nil
        return unless oi = @open_index
        n = @menus.size
        return if n == 0
        open (((oi + dir) % n) + n) % n
      end

      private def on_menu_hidden(menu : Menu) : Nil
        i = @menus.index menu
        @open_index = nil if i && @open_index == i
        sync_highlight
      end

      # *menu* lost focus. Close it unless focus stayed inside the bar's world:
      # diving into *menu*'s own submenu, returning to the bar, or moving to
      # another of the bar's menus (hand-off while switching).
      private def on_menu_blur(menu : Menu, e) : Nil
        return unless (oi = @open_index) && @menus[oi]? == menu
        nf = e.el
        # Focus moved into this menu's own (sub)menu chain — still active.
        return if nf.is_a?(Menu) && (nf.parent_menu == menu || @menus.includes?(nf))
        # Focus returned to the bar itself — keep the menu open.
        return if nf == self
        close
      end

      # Absolute x of title *i* (0 before the bar is laid out).
      private def title_x(i : Int) : Int32
        items[i]?.try(&.aleft) || 0
      rescue
        0
      end

      # The row just below the bar.
      private def menu_y : Int32
        atop + aheight
      rescue
        1
      end

      # Title highlight tracks the *open* menu, not the action bar's raw
      # selection. `Mixin::ActionBar#trigger` re-`select_index`s the clicked item after
      # our toggle callback runs, so a click that closed the menu would otherwise
      # leave its title lit — the shared `#reapply_highlight` scaffold re-imposes
      # the open-menu highlight through this predicate.
      protected def highlight_item?(item : Widget, index : Int32, offset : Int32) : Bool
        index == @open_index
      end

      # Re-light the open menu's title outside a selection (focus/blur, a menu
      # opening/closing).
      private def sync_highlight : Nil
        reapply_highlight
      end

      # The pop-up menus are window children, so tear them down with the bar.
      def destroy
        # Withdraw the accelerators NOW, while `@menus` is still populated: the
        # `Detach` emitted during `super`'s teardown runs the uninstall handler
        # over an already-cleared collection, leaving every action's shortcut
        # registered on the window forever (firing against the torn-down UI and
        # pinning the actions alive).
        uninstall_menu_shortcuts window?
        @menus.each { |m| Widget.destroy_satellite m }
        @menus.clear
        super
      end
    end
  end
end
