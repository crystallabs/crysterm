require "./listbar"
require "./menu"

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
    # Built on `ListBar` (layout, keyboard navigation, hotkeys) and `Menu` (the
    # pop-ups), it packages the wiring an app would otherwise repeat by hand.
    #
    # ```
    # bar = Widget::MenuBar.new parent: screen, top: 0, left: 0, width: "100%", height: 1
    # file = bar.add_menu "File"
    # file.add("New") { new_doc }
    # file.add("Open") { open_doc }
    # bar.add_menu "Edit", [cut_action, copy_action]
    # ```
    class MenuBar < ListBar
      # The pop-up menus, parallel to the bar's commands/items.
      getter menus = [] of Menu

      # Style for the pop-up menus (defaults to a bordered box).
      property menu_style : Style?

      # Index of the currently open menu, or `nil` when none is open.
      getter open_index : Int32?

      def initialize(menu_style : Style? = nil, **listbar)
        @menu_style = menu_style

        # A menu bar is always keyboard- and mouse-driven, and shows plain titles
        # ("File", not the ListBar default "1:File").
        super(**listbar.merge(keys: true, mouse: true))
        @auto_prefix = false

        # Keep the highlight on the open menu (nothing when none is open), even as
        # focus enters/leaves the bar — the ListBar would otherwise re-light its
        # own selected item.
        on(::Crysterm::Event::Focus) { sync_highlight }
        on(::Crysterm::Event::Blur) { sync_highlight }
      end

      # Adds a top-level menu titled *title* (optionally pre-filled with
      # *actions*) and returns the `Menu` so more can be added to it.
      def add_menu(title : String, actions : Array(Action) = [] of Action) : Menu
        menu = Menu.new(screen: screen, style: @menu_style || Style.new(border: true))
        actions.each { |a| menu << a }
        menu.hide
        menu.on_navigate = ->(dir : Int32) { switch_relative dir }
        menu.on(::Crysterm::Event::Hide) { on_menu_hidden menu }

        index = @menus.size
        @menus << menu
        add(title) { open index } # ListBar command: click / Enter opens it

        # Hover a different title (while a menu is open) to switch to it.
        if item = items[index]?
          item.on(::Crysterm::Event::MouseOver) do
            open index if @open_index && @open_index != index
          end
        end

        sync_highlight # clear the ListBar's auto-selection of the first item
        menu
      end

      # Opens menu *i* (closing any other), positioned under its title.
      def open(i : Int) : Nil
        return unless menu = @menus[i]?
        @menus.each_with_index { |m, j| m.hide_popup if j != i && m.visible? }
        @open_index = i.to_i
        menu.popup title_x(i), menu_y
        highlight i
      end

      # Closes the open menu, if any.
      def close : Nil
        @open_index.try { |i| @menus[i]?.try &.hide_popup }
      end

      def on_keypress(e)
        # While focused, Down/Space (in addition to the inherited Enter) open the
        # highlighted menu; Left/Right navigation is inherited from `ListBar`.
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
