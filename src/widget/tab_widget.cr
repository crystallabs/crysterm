require "./box"
require "./listbar"

module Crysterm
  class Widget
    # Tabbed container, modeled after Qt's `QTabWidget`.
    #
    # Shows a horizontal tab bar (a `Widget::ListBar`) along the top and a stack
    # of pages below it; selecting a tab — with the arrow keys, Tab/Shift-Tab, a
    # click, or programmatically — raises the matching page and hides the others.
    #
    # ```
    # tabs = Widget::TabWidget.new parent: screen, width: 60, height: 20
    # tabs.add_tab "Files", Widget::Box.new(content: "...")
    # tabs.add_tab "Edit", Widget::Box.new(content: "...")
    # tabs.bar.focus # so the arrow keys switch tabs
    # ```
    class TabWidget < Box
      # The tab bar along the top. (Built in `initialize` after `super`, hence
      # `getter!`.)
      getter! bar : ListBar

      # The page widgets, parallel to `#tab_titles`.
      getter pages = [] of Widget

      # The tab titles, parallel to `#pages`.
      getter tab_titles = [] of String

      # Index of the currently visible page (`-1` until the first tab is added).
      getter current_index : Int32 = -1

      # Height (in rows) reserved for the tab bar.
      property tab_height : Int32 = 1

      # Guards against the bar↔page selection feedback loop (see `#show_tab`).
      @switching = false

      def initialize(tab_height = 1, **box)
        @tab_height = tab_height

        super **box

        @bar = ListBar.new(
          parent: self,
          top: 0,
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
      end

      # Appends a tab titled *title* whose body is *page*. The page is sized to
      # fill the area under the tab bar. The first tab added becomes current.
      def add_tab(title : String, page : Widget) : self
        @tab_titles << title
        @pages << page

        # Lay the page out below the bar, filling the rest of the widget.
        page.top = @tab_height
        page.left = 0
        page.right = 0
        page.bottom = 0
        append page

        index = @pages.size - 1

        # Suppress the bar's `SelectItem` (emitted by its own first-item
        # `selekt 0`) while adding, so it can't drive `show_tab` before the
        # visibility bookkeeping below runs.
        @switching = true
        bar.add(title) { show_tab index }
        @switching = false

        if current_index < 0
          show_tab 0
        else
          page.hide
        end

        self
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
