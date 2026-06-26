require "./box"
require "./menu"
require "../mixin/action_bar"

module Crysterm
  class Widget
    # Horizontal bar of pop-up menus, modeled after Qt's `QMenuBar`.
    #
    # Each title added with `#add_menu` drops a `Widget::Menu` when clicked (or
    # via Enter/Down/Space while the bar is focused). Once a menu is open, the bar
    # tracks the mouse and keyboard like a desktop menu bar: hovering — or arrowing
    # with Left/Right — onto another title switches to it (closing the previous);
    # the active title is highlighted, and nothing is highlighted while no menu is
    # open. Escape, an outside click, or activating a leaf closes the menu.
    #
    # Built on `Mixin::ActionBar` (layout, keyboard navigation, hotkeys) and
    # `Menu` (the pop-ups), it packages the wiring an app would otherwise repeat
    # by hand.
    #
    # ```
    # bar = Widget::MenuBar.new parent: screen, top: 0, left: 0, width: "100%", height: 1
    # file = bar.add_menu "File"
    # file.add("New") { new_doc }
    # file.add("Open") { open_doc }
    # bar.add_menu "Edit", [cut_action, copy_action]
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![MenuBar screenshot](../../examples/widget/menu_bar/menu_bar-capture5s.apng)
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

        # A menu bar is always keyboard- and mouse-driven, and shows plain titles
        # ("File", not the ActionBar default "1:File").
        super(**listbar.merge(keys: true))
        setup_action_bar mouse: true, auto_prefix: false
        # Titles pack flush — no inert gap cells between menus (only trailing the
        # last title). Each title box keeps its own side padding.
        @item_gap = 0

        # Keep the highlight on the open menu (nothing when none is open), even as
        # focus enters/leaves the bar — the action bar would otherwise re-light its
        # own selected item.
        on(::Crysterm::Event::Focus) { sync_highlight }
        on(::Crysterm::Event::Blur) { sync_highlight }
      end

      # Adds a top-level menu titled *title* (optionally pre-filled with
      # *actions*) and returns the `Menu` so more can be added to it.
      def add_menu(title : String, actions : Array(Action) = [] of Action) : Menu
        # `parent: screen` appends the pop-up to the screen so it actually renders
        # (a bare `screen:` would set the screen but leave it out of the render
        # tree — visible-flagged but never drawn).
        # Border/look come from the theme (`Menu { ... }`) unless the bar was
        # given an explicit `@menu_style`.
        menu = Menu.new(parent: screen, style: @menu_style)
        actions.each { |a| menu << a }
        menu.hide
        menu.on_navigate = ->(dir : Int32) { switch_relative dir }
        # The bar's own strip counts as "inside" the open menu's modal grab, so
        # hovering another title still switches menus while one is open.
        menu.grab_region = ->(x : Int32, y : Int32) { grab_contains? x, y }
        menu.on(::Crysterm::Event::Hide) { on_menu_hidden menu }

        index = @menus.size
        @menus << menu
        add(title) { toggle index } # action-bar command: click / Enter toggles it

        # Hover a different title (while a menu is open) to switch to it.
        if item = items[index]?
          item.on(::Crysterm::Event::MouseOver) do
            open index if @open_index && @open_index != index
          end
        end

        sync_highlight # clear the bar's auto-selection of the first item
        menu
      end

      # Opens menu *i* (closing any other), positioned under its title.
      def open(i : Int) : Nil
        return unless menu = @menus[i]?
        @menus.each_with_index { |m, j| m.hide_popup if j != i && m.visible? }
        @open_index = i = i.to_i
        # Move the bar's current item to the opened menu so a mouse hover-switch
        # also carries the keyboard cursor (otherwise Left/Right or Down would
        # resume from the previously-clicked title). `selekt` re-imposes the
        # open-menu highlight via the override below.
        selekt i
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
        # While focused, Down/Space (in addition to the inherited Enter) open the
        # highlighted menu; Left/Right navigation is inherited from `Mixin::ActionBar`.
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

      # The title highlight tracks the *open* menu, never the action bar's own raw
      # selection. `Mixin::ActionBar#trigger` re-`selekt`s the clicked item *after* our
      # toggle callback has run, so a click that closed the open menu would
      # otherwise leave its title lit — re-impose the open-menu highlight here.
      # (With no menu open this clears the highlight, matching the bar's "nothing
      # lit while closed" rule, including bare Left/Right navigation.)
      def selekt(offset : Int)
        super
        sync_highlight
      end

      # Highlights only *active*'s title (none when `nil`).
      private def highlight(active : Int32?) : Nil
        items.each_with_index { |it, j| it.state = (j == active) ? :selected : :normal }
      end

      private def sync_highlight : Nil
        highlight @open_index
      end

      # The pop-up menus are screen children, so tear them down with the bar.
      def destroy
        @menus.each do |m|
          screen?.try &.remove m
          m.destroy
        end
        @menus.clear
        super
      end
    end
  end
end
