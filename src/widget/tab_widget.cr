require "./box"
require "./listbar"

module Crysterm
  class Widget
    # Tabbed container, modeled after Qt's `QTabWidget`.
    #
    # Shows a tab bar (a `Widget::ListBar`) along the top — or the bottom, with
    # `#tab_position` — and a stack of pages filling the rest; selecting a tab
    # (arrow keys, Tab/Shift-Tab, a click, or programmatically) raises the
    # matching page and hides the others.
    #
    # With `#tabs_closable?` each tab shows a `✕` marker and can be closed with
    # the Delete key (on the focused bar) or by clicking its marker; `#movable?`
    # enables reordering the current tab with `<`/`>`.
    #
    # ```
    # tabs = Widget::TabWidget.new parent: screen, width: 60, height: 20, tabs_closable: true
    # tabs.add_tab "Files", Widget::Box.new(content: "...")
    # tabs.add_tab "Edit", Widget::Box.new(content: "...")
    # tabs.bar.focus # so the arrow keys switch tabs
    # ```
    class TabWidget < Box
      # Where the tab bar sits relative to the pages (Qt's `QTabWidget::North` /
      # `South`).
      enum Position
        Top
        Bottom
      end

      # The tab bar. (Built in `initialize` after `super`, hence `getter!`.)
      getter! bar : ListBar

      # The page widgets, parallel to `#tab_titles`.
      getter pages = [] of Widget

      # The tab titles, parallel to `#pages`.
      getter tab_titles = [] of String

      # Index of the currently visible page (`-1` until the first tab is added).
      getter current_index : Int32 = -1

      # Height (in rows) reserved for the tab bar.
      property tab_height : Int32 = 1

      # Where the tab bar is placed.
      property tab_position : Position = :top

      # Whether tabs show a `✕` marker and can be closed.
      property? tabs_closable : Bool = false

      # Whether the current tab can be reordered with `<`/`>`.
      property? movable : Bool = false

      # Guards against the bar↔page selection feedback loop (see `#show_tab`).
      @switching = false

      def initialize(tab_height = 1, tab_position : Position = :top, tabs_closable = false, movable = false, **box)
        @tab_height = tab_height
        @tab_position = tab_position
        @tabs_closable = tabs_closable
        @movable = movable

        super **box

        @bar = ListBar.new(
          parent: self,
          top: @tab_position.top? ? 0 : nil,
          bottom: @tab_position.bottom? ? 0 : nil,
          left: 0,
          right: 0,
          height: @tab_height,
          keys: true,
          mouse: true,
        )

        # Selecting a tab in the bar (arrow keys / click) raises its page.
        bar.on(::Crysterm::Event::SelectItem) do |e|
          show_tab e.index unless @switching
        end

        # Close (Delete) and reorder (`<`/`>`) the current tab from the bar.
        bar.on(::Crysterm::Event::KeyPress) do |e|
          if tabs_closable? && e.key == ::Tput::Key::Delete
            close_tab @current_index
            e.accept
          elsif movable? && e.char == '<'
            move_tab @current_index, @current_index - 1
            e.accept
          elsif movable? && e.char == '>'
            move_tab @current_index, @current_index + 1
            e.accept
          end
        end

        # Click a tab's `✕` marker to close it. The bar centers the item text, so
        # the `✕` sits one cell in from the right edge — accept either of the two
        # right-most cells of the box.
        bar.on(::Crysterm::Event::Mouse) do |e|
          next unless tabs_closable? && e.action.down?
          bar.items.each_with_index do |item, i|
            next unless item.visible?
            if e.y == item.atop && e.x >= item.aleft + item.awidth - 2 && e.x < item.aleft + item.awidth
              close_tab i
              e.accept
              break
            end
          end
        rescue
          # Item not laid out yet — ignore.
        end
      end

      # The title as shown in the bar (with a `✕` appended when closable).
      private def display_title(title : String) : String
        tabs_closable? ? "#{title} ✕" : title
      end

      # Appends a tab titled *title* whose body is *page*. The page is sized to
      # fill the area beside the tab bar. The first tab added becomes current.
      def add_tab(title : String, page : Widget) : self
        @tab_titles << title
        @pages << page

        layout_page page
        append page

        index = @pages.size - 1

        # Suppress the bar's `SelectItem` (emitted by its own first-item
        # `selekt 0`) while adding, so it can't drive `show_tab` before the
        # visibility bookkeeping below runs.
        @switching = true
        bar.add(display_title title) { show_tab index }
        @switching = false

        if current_index < 0
          show_tab 0
        else
          page.hide
        end

        self
      end

      # Positions *page* to fill the widget beside the tab bar.
      private def layout_page(page : Widget) : Nil
        page.left = 0
        page.right = 0
        if @tab_position.top?
          page.top = @tab_height
          page.bottom = 0
        else
          page.top = 0
          page.bottom = @tab_height
        end
      end

      # The currently visible page, or `nil` when there are no tabs.
      def current_page : Widget?
        @pages[@current_index]?
      end

      # Raises the page (and selects the tab) at *index*, hiding the others.
      def show_tab(index : Int) : Nil
        return unless 0 <= index < @pages.size
        return if index == @current_index

        @current_index = index.to_i
        @pages.each_with_index do |page, i|
          i == index ? page.show : page.hide
        end

        # Mirror the selection in the bar without re-triggering this handler.
        unless bar.selected == index
          @switching = true
          bar.selekt index
          @switching = false
        end

        request_render
      end

      # Removes the tab at *index*, detaching (but **not** destroying) its page
      # and returning it — Qt's `removeTab` likewise leaves page ownership with
      # the caller. Keeps a valid current tab and emits `Event::RemoveItem`.
      def remove_tab(index : Int) : Widget?
        return nil unless 0 <= index < @pages.size

        page = @pages.delete_at index
        @tab_titles.delete_at index

        @switching = true
        bar.remove_item index
        @switching = false

        remove page

        # Re-point current_index at a still-existing tab and show it.
        @current_index = -1
        unless @pages.empty?
          show_tab index.clamp(0, @pages.size - 1)
        end

        emit ::Crysterm::Event::RemoveItem
        request_render
        page
      end

      # Like `#remove_tab`, but also destroys the detached page. This is the
      # destructive action behind the `✕`/Delete UI affordances.
      def close_tab(index : Int) : Nil
        remove_tab(index).try &.destroy
      end

      # Moves the tab at *from* to *to* (clamped), keeping the same page current.
      def move_tab(from : Int, to : Int) : Nil
        return if @pages.empty?
        to = to.clamp(0, @pages.size - 1)
        return if from == to || !(0 <= from < @pages.size)

        current = current_page

        @pages.insert to, @pages.delete_at(from)
        @tab_titles.insert to, @tab_titles.delete_at(from)

        # Rebuild the bar from the reordered titles.
        @switching = true
        bar.set_items @tab_titles.map { |t| display_title t }
        @tab_titles.each_with_index do |_, i|
          bar.commands[i].callback = -> { show_tab i }
        end
        @switching = false

        # Restore the previously-current page as current.
        @current_index = -1
        if current && (i = @pages.index current)
          show_tab i
        else
          show_tab to
        end
      end

      # Selects the next tab (wrapping at the end).
      def next_tab : Nil
        return if @pages.empty?
        show_tab (@current_index + 1) % @pages.size
      end

      # Selects the previous tab (wrapping at the start).
      def previous_tab : Nil
        return if @pages.empty?
        show_tab (@current_index - 1) % @pages.size
      end
    end
  end
end
