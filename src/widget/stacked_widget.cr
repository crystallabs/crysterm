require "./box"

module Crysterm
  class Widget
    # A stack of pages of which exactly one is visible at a time, modeled after
    # Qt's `QStackedWidget`. Like `Widget::TabWidget` but with no tab bar — the
    # visible page is chosen programmatically (or by another widget you wire up).
    #
    # ```
    # stack = Widget::StackedWidget.new parent: screen, width: 40, height: 12
    # stack.add_page Widget::Box.new(content: "page 1")
    # stack.add_page Widget::Box.new(content: "page 2")
    # stack.current = 1
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![StackedWidget screenshot](../../examples/widget/stacked_widget/stacked_widget-capture.png)
    # <!-- /widget-examples:capture -->
    class StackedWidget < Box
      # The pages, in insertion order.
      getter pages = [] of Widget

      # Index of the visible page (`-1` until the first page is added).
      getter current_index : Int32 = -1

      # Appends *page*, sized to fill the widget. The first page added becomes
      # current; later ones come up hidden.
      def add_page(page : Widget) : self
        page.top = 0
        page.left = 0
        page.right = 0
        page.bottom = 0
        @pages << page
        append page

        if current_index < 0
          show_page 0
        else
          page.hide
        end

        self
      end

      # Number of pages.
      def count : Int32
        @pages.size
      end

      # The currently visible page, or `nil` when there are none.
      def current_page : Widget?
        @pages[@current_index]?
      end

      # Raises the page at *index*, hiding the others. No-op for an out-of-range
      # index or the already-current page.
      def show_page(index : Int) : Nil
        return unless 0 <= index < @pages.size
        return if index == @current_index
        @current_index = index.to_i
        @pages.each_with_index do |page, i|
          i == index ? page.show : page.hide
        end
        request_render
      end

      # :ditto:
      def current=(index : Int)
        show_page index
      end

      def next_page : Nil
        return if @pages.empty?
        show_page((@current_index + 1) % @pages.size)
      end

      def previous_page : Nil
        return if @pages.empty?
        show_page((@current_index - 1) % @pages.size)
      end
    end
  end
end
