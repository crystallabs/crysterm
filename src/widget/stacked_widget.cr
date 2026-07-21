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
    # stack.add_widget Widget::Box.new(content: "page 1")
    # stack.add_widget Widget::Box.new(content: "page 2")
    # stack.current_index = 1
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![StackedWidget screenshot](../../tests/widget/stacked_widget/stacked_widget.5s.apng)
    # <!-- /widget-examples:capture -->
    class StackedWidget < Box
      # `#pages`, `#count`, `#current_index=`, `#current_widget=` and the
      # show/`next_page`/`previous_page` core all come from here.
      include Mixin::PagedContainer

      # Appends *page*, sized to fill the widget (Qt's `QStackedWidget#addWidget`).
      # The first page added becomes current; later ones come up hidden.
      def add_widget(page : Widget) : self
        stretch_child page
        @pages << page
        append page
        register_page page
        self
      end

      # Inserts *page* at *index* (clamped to the end), sized to fill the widget
      # (Qt's `QStackedWidget#insertWidget`). The visible page stays current,
      # following its shift; if the stack was empty the inserted page becomes
      # current. Returns `self`.
      def insert_widget(index : Int, page : Widget) : self
        i = index.clamp(0, @pages.size)
        cur = current_widget
        stretch_child page
        @pages.insert i, page
        append page
        if cur
          page.hide
          # The inserted page shifts the current one's index up when it lands at
          # or before it; re-resolve rather than emit a spurious `CurrentChanged`.
          @current_index = @pages.index(cur) || @current_index
        else
          register_page page
        end
        self
      end

      # Removes *page* from the stack, detaching (not destroying) it, and returns
      # it — or `nil` when it is not in this stack (Qt's `QStackedWidget#removeWidget`).
      # Keeps a valid current page visible.
      def remove_widget(page : Widget) : Widget?
        i = @pages.index page
        return unless i
        cur = current_widget
        @pages.delete_at i
        remove page
        if @pages.empty?
          clear_current_index
        else
          # `-1` first: the surviving current page may sit at the same index it
          # did before, and `#show_index` no-ops on the already-current one.
          @current_index = -1
          if cur && cur != page && (ci = @pages.index(cur))
            self.current_index = ci
          else
            self.current_index = i.clamp(0, @pages.size - 1)
          end
        end
        page
      end

      # Operator alias for `#add_widget`, e.g. `stack << page`. Deliberately
      # overrides the inherited `Mixin::Children#<<` (a raw child append): a
      # `StackedWidget`'s children are pages, so every append must also register
      # the page's paged-container bookkeeping. `#add_widget` calls `append`
      # itself, so the child is still attached.
      def <<(page : Widget) : self
        add_widget page
      end
    end
  end
end
