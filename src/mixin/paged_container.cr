module Crysterm
  module Mixin
    # Shared paged-container machinery: a list of `#pages` of which exactly one is
    # visible at a time, identified by `#current_index`. Factored out of
    # `Widget::StackedWidget` (Qt's `QStackedWidget`) and `Widget::TabWidget`
    # (Qt's `QTabWidget`), which both keep parallel pages, raise one and hide the
    # rest, and step through them with wrap-around.
    #
    # The including widget appends its own pages to `#pages` (with whatever sizing
    # it needs), then drives selection through the protected `#show_index`,
    # `#next_index` and `#previous_index` core — usually behind its own
    # domain-named public methods (`show_page`/`show_tab`, …). Per-widget work
    # after a switch (e.g. `TabWidget` mirroring the selection in its tab bar) goes
    # in `#after_show_index`, the default being a no-op.
    module PagedContainer
      # The pages, in insertion order.
      getter pages = [] of Widget

      # Index of the visible page (`-1` until the first page is added).
      getter current_index : Int32 = -1

      # The currently visible page, or `nil` when there are none.
      def current_page : Widget?
        # Guard the `-1` sentinel explicitly: Crystal's `[]?` treats a negative
        # index as counting from the end, so `@pages[-1]?` would wrongly return
        # the last page instead of `nil`.
        return nil if @current_index < 0
        @pages[@current_index]?
      end

      # Raises the page at *index*, hiding the others. No-op for an out-of-range
      # index or the already-current page.
      protected def show_index(index : Int) : Nil
        return unless 0 <= index < @pages.size
        return if index == @current_index
        @current_index = index.to_i
        @pages.each_with_index do |page, i|
          i == index ? page.show : page.hide
        end
        after_show_index index
        request_render
      end

      # Hook for per-widget work after the visible page changes (e.g. mirroring
      # the selection elsewhere). Default: nothing.
      protected def after_show_index(index : Int) : Nil
      end

      # Finalizes the visibility of a freshly-added *page*: the first page added
      # (`@current_index` still the `-1` sentinel) is raised via `#show_index 0`
      # and becomes current; every later one comes up hidden. Call after pushing
      # *page* onto `#pages` and appending its child — each container appends with
      # its own sizing, and `TabWidget` needs the new index in between, so the
      # push/append stay at the call site.
      protected def register_page(page : Widget) : Nil
        if @current_index < 0
          show_index 0
        else
          page.hide
        end
      end

      # Selects the next page, wrapping at the end.
      protected def next_index : Nil
        return if @pages.empty?
        show_index((@current_index + 1) % @pages.size)
      end

      # Selects the previous page, wrapping at the start.
      protected def previous_index : Nil
        return if @pages.empty?
        # Guard the `-1` sentinel explicitly, mirroring `#current_page`: a raw
        # `(@current_index - 1) % size` maps `-1` to `size - 2`, silently
        # skipping the last page. From unselected, "previous" should wrap to the
        # last page, symmetric with `#next_index` landing on the first.
        i = @current_index < 0 ? @pages.size - 1 : (@current_index - 1) % @pages.size
        show_index i
      end
    end
  end
end
