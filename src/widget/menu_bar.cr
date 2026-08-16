require "./box"
require "./menu"
require "../mixin/action_bar"
require "../mnemonic"

module Crysterm
  class Widget
    # Horizontal bar of pop-up menus, modeled after Qt's `QMenuBar`.
    #
    # Each title added with `#add_menu` drops a `Widget::Menu` when clicked (or
    # via Enter/Down/Up/Space while the bar is focused; keyboard-opened menus
    # start with an entry selected). Once a menu is open, hovering or arrowing
    # with Left/Right onto another title switches to it (closing the previous);
    # the active title is highlighted, none when no menu is open. Within the
    # menu, Up/Down wrap at the ends, Right enters the highlighted submenu (or
    # moves to the next title when there is none to enter), and Left backs out
    # one submenu level (or moves to the previous title from the top level).
    # Escape, an outside click, or activating a leaf closes the menu.
    #
    # The bar sits off the window's Tab chain (Qt-style chrome); the keyboard
    # reaches it via `#activation_key` (F10 by default), an `Alt+<letter>`
    # title mnemonic (`add_menu "&File"`), or the window's F6/Shift+F6 region
    # cycle, and Escape steps back out — see `window_region_focus.cr`.
    #
    # ```
    # bar = Widget::MenuBar.new parent: window, top: 0, left: 0, width: "100%", height: 1
    # file = bar.add_menu "File"
    # file.add_action("New") { new_doc }
    # file.add_action("Open") { open_doc }
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

      # Each menu's mnemonic letter (downcased; `nil` for none), parallel to
      # `#menus` — parsed from the Qt-style `&` marker in the title
      # (`add_menu "&File"`). `Alt+<letter>` opens the menu from anywhere;
      # with the bar active and no menu open, the bare letter does too.
      getter mnemonics = [] of Char?

      # Style for the pop-up menus (defaults to a bordered box).
      property menu_style : Style?

      # Index of the currently open menu, or `nil` when none is open.
      getter open_index : Int32?

      # Window-level key that activates the bar from anywhere (the F10 of
      # Windows/GTK apps; Midnight Commander users may prefer `F9`): pressed
      # once, it remembers the focused widget and focuses the bar; pressed
      # again — or Escape with no menu open — it closes any open menu and
      # returns focus to that widget. `nil` disables the feature. Read at
      # press time, so it can be reassigned (or disabled) at any moment.
      property activation_key : Tput::Key? = Tput::Key::F10

      # The window-level `KeyPress` subscription watching `#activation_key`,
      # while the bar is attached.
      @activation_subscription : ::Crysterm::Subscription?

      def initialize(menu_style : Style? = nil, **command_bar)
        @menu_style = menu_style

        # Always keyboard/mouse-driven, plain titles ("File", not ActionBar's default "1:File").
        super(**command_bar.merge(keys: true))
        # Window chrome: the window's Tab/Shift+Tab cycle steps over the bar by
        # default (as in Qt, a menu bar is reached by click or its accelerators,
        # not the Tab chain). A click still focuses it, and Left/Right/Enter
        # work as before once focused. An explicit `focus_policy:` argument
        # (applied by `super` above) wins over this default.
        self.focus_policy = FocusPolicy::Click unless @focus_policy
        # Keyboard-reachable chrome: the F6/Shift+F6 region cycle (see
        # `window_region_focus.cr`) can land on the bar even though Tab steps
        # over it. Turn off via `region_focusable = false`.
        @region_focusable = true
        setup_action_bar mouse: true, auto_prefix: false
        # Titles pack flush (only trailing the last title); each keeps its own side padding.
        @item_gap = 0

        # Keep the highlight on the open menu regardless of bar focus; the action
        # bar would otherwise re-light its own selected item.
        on(::Crysterm::Event::FocusIn) { sync_highlight }
        on(::Crysterm::Event::FocusOut) { sync_highlight }

        # Wire menu actions' keyboard accelerators to the window lifecycle, so e.g.
        # "Copy" (Ctrl+C) fires without opening the menu first (Qt's menu-action
        # shortcuts). Menus must be rehomed first, so they open on the bar's window
        # — that is what `#before_install_action_shortcuts` below is for.
        wire_action_shortcuts

        # `#activation_key` is a window-level accelerator, so it follows the
        # attach lifecycle — plus one direct install: a bar built with
        # `parent:` was attached during `super`, before these handlers existed,
        # so `Attached` has already fired for it.
        on(::Crysterm::Event::Attached) { install_activation_key }
        on(::Crysterm::Event::Detached) { uninstall_activation_key }
        install_activation_key
      end

      # Subscribes the `#activation_key` watcher on the bar's window. Installed
      # as a plain window-level `KeyPress` handler (like `Action` accelerators),
      # so it runs after the focused widget's key walk and only ever sees keys
      # nothing else consumed.
      private def install_activation_key : Nil
        w = window? || return
        return if @activation_subscription
        s = ::Crysterm::Subscription.new
        s.on(w, ::Crysterm::Event::KeyPress) { |e| on_activation_key e }
        @activation_subscription = s
      end

      # Withdraws the `#activation_key` watcher (the subscription remembers the
      # window it is on, so this needs no window argument).
      private def uninstall_activation_key : Nil
        @activation_subscription.try &.off
        @activation_subscription = nil
      end

      # Handles a window-level keypress nothing else consumed: `#activation_key`
      # toggles between activating the bar (remembering the focused widget) and
      # deactivating it (closing any open menu and giving that widget focus
      # back); `Alt+<letter>` opens the matching mnemonic's menu directly. The
      # remember/return legwork is the window's region-focus machinery
      # (`Window#focus_region`/`#focus_central`), shared with F6 cycling.
      private def on_activation_key(e : ::Crysterm::Event::KeyPress) : Nil
        return if e.accepted?
        w = window? || return
        if (key = @activation_key) && e.key == key
          e.accept
          if @open_index || w.region_of(w.focused).same?(self)
            close
            w.focus_central
          else
            # Windows convention: activation always lights the FIRST title (via
            # `#highlight_item?` once the focus lands), not wherever the cursor
            # sat when the bar was last left.
            self.current_index = 0
            w.focus_region self
          end
          w.update
        elsif (c = alt_char(e)) && (i = @mnemonics.index(c))
          e.accept
          # Entering from the central area records the return slot; with the
          # bar already active (or one of its menus open — an open pop-up is a
          # *window* child, so it must not be recorded as "central"), this is a
          # plain menu open/switch.
          w.focus_region self unless @open_index || w.region_of(w.focused).same?(self)
          open_selected i
          w.update
        end
      end

      # The letter of an Alt+letter chord, or `nil`: legacy input encodes it as
      # its own key (`ESC f` → `AltA`..`AltZ`, contiguous), the enhanced
      # keyboard protocol as the plain character with the alt modifier.
      private def alt_char(e : ::Crysterm::Event::KeyPress) : Char?
        if (k = e.key) && ::Tput::Key::AltA <= k <= ::Tput::Key::AltZ
          'a' + (k.value - ::Tput::Key::AltA.value)
        elsif e.alt? && (c = e.char) && c != '\0'
          c.downcase
        end
      end

      # Opens menu *i* the keyboard way — with its first entry selected, like
      # any keyboard-opened menu (`Down`/`Space` on the bar, a mnemonic).
      private def open_selected(i : Int32) : Nil
        open_menu i
        @menus[i]?.try &.select_first_action
      end

      # Adds a top-level menu titled *title* (optionally pre-filled with
      # *actions*) and returns the `Menu` so more can be added to it.
      #
      # *title* accepts a Qt-style `&` mnemonic (`"&File"`): the marked letter
      # renders underlined, `Alt+<letter>` opens the menu from anywhere, and —
      # with the bar active and no menu open — so does the bare letter. `"&&"`
      # renders a literal ampersand.
      def add_menu(title : String, actions : Array(Action) = [] of Action) : Menu
        # `parent: window` appends the pop-up to the render tree so it actually
        # draws (a bare `window:` would leave it visible-flagged but undrawn).
        menu = Menu.new(parent: window, style: @menu_style)
        # Batched: one row rebuild for the whole pre-fill instead of one per
        # action (see `Menu#begin_update`).
        menu.batch_update { actions.each { |a| menu << a } }
        # The bar is normally already attached, so wire accelerators now; a later
        # re-attach re-covers them.
        window?.try { |w| visit_actions(menu, &.install_shortcut(w, self)) }
        menu.hide
        menu.navigate_handler { |dir| switch_relative dir }
        # A leaf activation dismisses the whole chain — deactivate the bar too
        # (Windows semantics): focus returns to the central area, so the fired
        # command doesn't leave the bar focused with a lit title.
        menu.chain_activated_handler { deactivate_after_activation }
        # The bar's own strip counts as "inside" the open menu's modal grab, so
        # hovering another title still switches menus while one is open.
        menu.treat_as_inside { |x, y| grab_contains? x, y }
        menu.on(::Crysterm::Event::Hide) { on_menu_hidden menu }
        # Actions added *after* this call (`file << action` on an attached bar)
        # need their accelerators too: the menu emits `SetItems` on every
        # structural change, so re-run the idempotent install then. Scope it to
        # the changed menu — `SetItems` fires per-add while a bar is built, so
        # re-walking *every* menu's actions each time is ~O((M·A)²) for an
        # identical final state.
        menu.on(::Crysterm::Event::ItemsChanged) { install_menu_shortcuts menu }
        # Close the menu when it loses focus to something outside the bar's world
        # (mouse-click dismissal is handled separately by `Menu#popup`'s
        # `on_press_outside`). Diving into a submenu or moving to the bar/another
        # menu is an internal move and is ignored.
        menu.on(::Crysterm::Event::FocusOut) { |e| on_menu_blur menu, e }

        index = @menus.size
        @menus << menu
        # `&` mnemonic: strip the marker, remember the letter, underline it in
        # the rendered title (the item boxes are `parse_tags`-enabled).
        display, mnemonic = Mnemonic.tagged title
        @mnemonics << mnemonic
        add_item(display) { toggle_menu index } # action-bar command: click / Enter toggles it

        # Hover a different title (while a menu is open) to switch to it.
        if item = item_boxes[index]?
          item.on(::Crysterm::Event::MouseEnter) do
            open_menu index if @open_index && @open_index != index
          end
        end

        sync_highlight # clear the bar's auto-selection of the first item
        menu
      end

      # The bar owns every action in every pop-up (descending into submenus), on
      # top of any installed with `Widget#add_action`.
      private def each_shortcut_action(&block : Action ->) : Nil
        super(&block)
        @menus.each { |m| visit_actions(m, &block) }
      end

      # The pop-ups must sit on the bar's *current* window before their actions'
      # accelerators are (re)installed there.
      private def before_install_action_shortcuts : Nil
        rehome_menus
      end

      # Installs a single *menu*'s action accelerators (descending into
      # submenus). Idempotent per window; used for the incremental `ItemsChanged`
      # refresh, where re-walking every menu would be quadratic.
      private def install_menu_shortcuts(menu : Menu) : Nil
        w = window? || return
        visit_actions(menu, &.install_shortcut(w, self))
      end

      # Moves any pop-up menu still hosted on a previous window over to the
      # bar's current one (safe while closed — the menus are hidden window
      # children), so a cross-window reparent doesn't leave the menus opening
      # (and taking their modal grab) on the old window.
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
      #
      # Named `open_menu`, not `open`: `Dialog#open` is the toolkit's dialog
      # presentation verb, and a bare `MenuBar#open(i)` read like it.
      def open_menu(i : Int) : Nil
        return unless menu = @menus[i]?
        @menus.each_with_index { |m, j| m.hide_popup if j != i && m.visible? }
        @open_index = i = i.to_i
        # Move the bar's current item to match, so hover-switching also carries
        # the keyboard cursor.
        self.current_index = i
        menu.popup title_x(i), menu_y
      end

      # Toggles menu *i*: opens it, or closes it (deselecting the title) if it is
      # already the open one — matching the click behavior of desktop menu bars.
      #
      # Named `toggle_menu`, not `toggle`: `AbstractButton#toggle` is the
      # toolkit's check-state verb.
      def toggle_menu(i : Int) : Nil
        if @open_index == i.to_i
          close
        else
          open_menu i
        end
      end

      # Closes the open menu, if any.
      def close : Nil
        @open_index.try { |i| @menus[i]?.try &.hide_popup }
      end

      def handle_key_press(e)
        # Down/Up/Space open the highlighted menu (Enter and Left/Right come from
        # `Mixin::ActionBar`). Keyboard-opened, the menu drops with an entry
        # already selected — the first for Down/Space, the last for Up (cycling
        # backward, Qt-like) — unlike a clicked-open menu, which drops
        # unhighlighted until hovered.
        if (e.key == ::Tput::Key::Down || e.key == ::Tput::Key::Up || e.char == ' ') && !@menus.empty?
          i = current_index
          open_menu i
          @menus[i]?.try { |m| e.key == ::Tput::Key::Up ? m.select_last_action : m.select_first_action }
          e.accept
          return
        end

        # With the bar active and no menu open, a bare mnemonic letter opens
        # its menu — how Windows/Qt menu bars behave after F10/Alt activation.
        # (Space never reaches here — the branch above owns it.)
        if @open_index.nil? && (c = e.char) && c != '\0' && (i = @mnemonics.index(c.downcase))
          open_selected i
          e.accept
          return
        end
        super
      end

      # Switches to the menu *dir* away (wrapping), as Left/Right does with a
      # menu open. A keyboard switch, so the newly opened menu starts with its
      # first entry selected, like any keyboard-opened menu.
      private def switch_relative(dir : Int32) : Nil
        return unless oi = @open_index
        n = @menus.size
        return if n == 0
        i = (((oi + dir) % n) + n) % n
        open_menu i
        @menus[i]?.try &.select_first_action
      end

      # Fully deactivates the bar after a menu action fired: focus goes back to
      # the central area — the F10/F6 return slot when one is set, else the
      # first central Tab target (`Window#focus_central` handles both). The
      # menus are already closed (and focus already rewound onto the bar) by
      # the time the `chain_activated_handler` hook runs.
      private def deactivate_after_activation : Nil
        w = window? || return
        w.focus_central
        w.update
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
        nf = e.next_focused
        # Focus moved into this menu's own (sub)menu chain — still active.
        return if nf.is_a?(Menu) && (nf.parent_menu == menu || @menus.includes?(nf))
        # Focus returned to the bar itself — keep the menu open.
        return if nf == self
        close
      end

      # Absolute x of title *i* (0 before the bar is laid out). Uses the item
      # box's *painted* rect (`Widget#painted_rect`), not its layout coords —
      # see `#menu_y`.
      private def title_x(i : Int) : Int32
        item_boxes[i]?.try(&.painted_rect.x) || 0
      rescue
        0
      end

      # The row just below the bar. Anchored on the bar's *painted* rect
      # (`Widget#painted_rect`), not its layout coords: inside a
      # scrolled/child_base ancestor the two diverge by the ancestor's scroll
      # base, and the pop-up menu (a window child) is painted exactly where we
      # put it — so layout coords would drop it detached from the visible bar.
      # Mirrors ComboBox#place_popup / DateEdit#position_popup.
      private def menu_y : Int32
        r = painted_rect
        r.y + r.height
      rescue
        1
      end

      # Title highlight tracks the *open* menu, not the action bar's raw
      # selection: `ActionBar#trigger` re-selects (`current_index=`) the clicked item after
      # the toggle callback runs, so a click that closed the menu would otherwise
      # leave its title lit.
      #
      # With no menu open, a *focused* bar highlights the current title instead —
      # the visual cue that F10/F6 landed keyboard focus on the bar (and that
      # Left/Right now walk the titles). A deliberate divergence from Qt, which
      # gives no cue until a menu drops; Windows and Midnight Commander both
      # light the title on activation. Unfocused with nothing open: no highlight.
      # (*offset* — not `current_index` — is the selection being applied:
      # `current_index=` re-highlights *before* updating its index fields, so
      # reading `current_index` here would light the stale title.)
      protected def highlight_item?(item : Widget, index : Int32, offset : Int32) : Bool
        if oi = @open_index
          index == oi
        else
          focused? && index == offset
        end
      end

      # Re-light the open menu's title outside a selection (focus/blur, a menu
      # opening/closing).
      private def sync_highlight : Nil
        reapply_highlight
      end

      # The pop-up menus are window children, so tear them down with the bar.
      def destroy
        # Must happen while `@menus` is still populated: the `Detached` emitted
        # during `super`'s teardown runs the uninstall handler over an
        # already-cleared collection, leaving every action's shortcut registered
        # on the window forever.
        uninstall_action_shortcuts window?
        @menus.each { |m| Widget.destroy_satellite m }
        @menus.clear
        @mnemonics.clear
        super
      end
    end
  end
end
