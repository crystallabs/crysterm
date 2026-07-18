require "./box"
require "../mixin/paged_container"

module Crysterm
  class Widget
    # A stack of pages of which exactly one is visible at a time, modeled after
    # Qt's `QStackedWidget`. Like `Widget::TabWidget` but with no tab bar — the
    # visible page is chosen programmatically (or by another widget you wire up).
    #
    # ```
    # stack = Widget::StackedWidget.new parent: window, width: 40, height: 12
    # stack.add_page Widget::Box.new(content: "page 1")
    # stack.add_page Widget::Box.new(content: "page 2")
    # stack.current_index = 1
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![StackedWidget screenshot](../../tests/widget/stacked_widget/stacked_widget.5s.apng)
    # <!-- /widget-examples:capture -->
    class StackedWidget < Box
      # `#pages`, `#count`, `#current_index=`, `#current_widget=` and the
      # show/next/previous core all come from here.
      include Mixin::PagedContainer

      # Appends *page*, sized to fill the widget. The first page added becomes
      # current; later ones come up hidden.
      def add_page(page : Widget) : self
        stretch_child page
        @pages << page
        append page
        register_page page
        self
      end

      def next_page : Nil
        next_index
      end

      def previous_page : Nil
        previous_index
      end
    end
  end
end
