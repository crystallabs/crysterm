module Crysterm
  module Mixin
    # Shared paged-container machinery: a list of `#pages` of which exactly one is
    # visible at a time, identified by `#current_index`. Provides the common
    # vocabulary — `#count`, `#current_index` / `#current_index=`,
    # `#current_widget` / `#current_widget=`, `#next_page` / `#previous_page`, and
    # `Event::CurrentChanged` (Qt's `currentChanged(int)`) on every change. Each
    # including widget keeps only the *adding* verb its domain wants
    # (`#add_widget`/`#add_tab`/`#add_item`).
    #
    # The including widget appends its own pages to `#pages` (with whatever sizing
    # it needs), then drives selection through the protected `#show_index`,
    # `#next_index` and `#previous_index` core. Per-widget work after a switch goes
    # in `#after_show_index`, the default being a no-op.
    module PagedContainer
      # The pages, in insertion order.
      getter pages = [] of Widget

      # Index of the visible page (`-1` until the first page is added). Assigning
      # raises that page and hides the others; out-of-range is a no-op (Qt's
      # `setCurrentIndex`).
      getter current_index : Int32 = -1

      # :ditto:
      def current_index=(index : Int) : Nil
        show_index index
      end

      # Number of pages (Qt's `count`).
      def count : Int32
        @pages.size
      end

      # The page at *index*, or `nil` when out of range (Qt's every
      # multi-child container's `widget(index)`, e.g. `QTabWidget#widget`).
      # `Splitter` already re-implements this (panes aren't `#pages`-backed).
      def widget(index : Int) : Widget?
        @pages[index]?
      end

      # Index of *page* among the pages, or `nil` when it is not one (Qt's
      # `indexOf`, which returns `-1`; this returns the idiomatic `nil`).
      # `Splitter` already re-implements this.
      def index_of(page : Widget) : Int32?
        @pages.index page
      end

      # The currently visible page, or `nil` when there are none (Qt's
      # `currentWidget`).
      def current_widget : Widget?
        # Crystal's `[]?` counts a negative index from the end, so `@pages[-1]?`
        # would return the last page instead of `nil`.
        return if @current_index < 0
        @pages[@current_index]?
      end

      # Raises *page*, hiding the others (Qt's `setCurrentWidget`). A page this
      # container doesn't hold is a no-op.
      def current_widget=(page : Widget) : Nil
        (i = @pages.index page) && show_index(i)
      end

      # Selects the next page, wrapping at the end. The single navigation spelling
      # shared by every paged container (`StackedWidget`, `TabWidget`, …) rather
      # than a per-widget `next_tab`/`next_section`.
      def next_page : Nil
        next_index
      end

      # Selects the previous page, wrapping at the start (the counterpart to
      # `#next_page`).
      def previous_page : Nil
        previous_index
      end

      # Raises the page at *index*, hiding the others, and emits
      # `Event::CurrentChanged`. No-op for an out-of-range index or the
      # already-current page.
      protected def show_index(index : Int) : Nil
        return unless 0 <= index < @pages.size
        return if index == @current_index
        @current_index = index.to_i
        @pages.each_with_index do |page, i|
          i == index ? page.show : page.hide
        end
        after_show_index index
        emit ::Crysterm::Event::CurrentChanged, @current_index
        update!
      end

      # Drops the selection back to the `-1` sentinel and announces it. For a
      # container that just lost its last page: there is nothing left to
      # `#show_index`, so nothing else would report the change.
      protected def clear_current_index : Nil
        return if @current_index < 0
        @current_index = -1
        emit ::Crysterm::Event::CurrentChanged, -1
      end

      # Restores a valid selection after a page was removed. Call it *after*
      # deleting the page (and whatever parallel per-widget data rides alongside
      # it) from `#pages`, passing the index the page occupied and the widget
      # that should stay current — the one current *before* the removal, or `nil`.
      # The single reclamp shared by every removal path (`#remove_tab`,
      # `#remove_widget`, `#remove_item`, and the `#remove` overrides that catch a
      # direct `destroy`/detach), so the `-1`-first dance lives in one place.
      #
      # * No pages left — drops to the `-1` sentinel via `#clear_current_index`,
      #   which emits `CurrentChanged(-1)` (nothing else would report it).
      # * *kept_widget* survived — re-shows it at its (possibly shifted) index.
      #   It may still sit at the very index it did before, and `#show_index`
      #   no-ops on the already-current page, so `@current_index` is reset to the
      #   `-1` sentinel first to force the switch — and any per-widget
      #   `#after_show_index` work (bar highlight, relayout) — to run.
      # * Otherwise (the current page *was* the one removed, so it is gone from
      #   `#pages`) — falls back to the neighbor at *removed_index*, clamped into
      #   the now-shorter list.
      protected def reclamp_after_removal(removed_index : Int, kept_widget : Widget?) : Nil
        if @pages.empty?
          clear_current_index
        else
          @current_index = -1
          if kept_widget && (ci = @pages.index(kept_widget))
            self.current_index = ci
          else
            self.current_index = removed_index.clamp(0, @pages.size - 1)
          end
        end
      end

      # The two samples a `#remove` override must take *before* it calls `super`:
      # the index *element* occupies in `#pages` (`nil` when the detached child
      # isn't a page at all — a tab bar, a header row) and the page that is
      # current right now. Both readings are only valid before `super` detaches
      # the child; pair with `#finish_page_removal` after it.
      protected def page_removal_snapshot(element) : Tuple(Int32?, Widget?)
        {@pages.index(element), current_widget}
      end

      # The other half of a `#remove` override, run *after* `super` with the
      # `#page_removal_snapshot` taken before it. A non-page child (`nil` index)
      # passes straight through. Otherwise the page is dropped from `#pages`, the
      # block is yielded its index for whatever per-widget teardown rides
      # alongside (parallel arrays, bar/header rows, re-pointing captured
      # indices), and `#reclamp_after_removal` restores a valid selection.
      # Returns whether a page was actually removed, so the caller can keep any
      # announcement (`Event::ItemRemoved`) *after* the reclamp, where it was.
      #
      # The block deliberately runs *after* `@pages.delete_at`: the parallel
      # arrays are independent of `#pages`, so the relative order of the two
      # deletes is immaterial, but re-entrancy is not — a teardown that detaches
      # another child of this same container (`ToolBox` removing the section's
      # header row) re-enters `#remove`, and that nested call must see `#pages`
      # already shrunk.
      protected def finish_page_removal(snapshot : Tuple(Int32?, Widget?), &) : Bool
        idx, kept = snapshot
        return false unless idx
        @pages.delete_at idx
        yield idx
        reclamp_after_removal idx, kept
        true
      end

      # :ditto: — for a container with no per-widget teardown to do.
      protected def finish_page_removal(snapshot : Tuple(Int32?, Widget?)) : Bool
        finish_page_removal(snapshot) { }
      end

      # Hook for per-widget work after the visible page changes. Default: nothing.
      protected def after_show_index(index : Int) : Nil
      end

      # Finalizes the visibility of a freshly-added *page*: the first page added
      # (`@current_index` still the `-1` sentinel) is raised via `#show_index 0`
      # and becomes current; every later one comes up hidden. Call after pushing
      # *page* onto `#pages` and appending its child.
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
        # A raw `(@current_index - 1) % size` maps the `-1` sentinel to
        # `size - 2`, silently skipping the last page. From unselected,
        # "previous" wraps to the last page.
        i = @current_index < 0 ? @pages.size - 1 : (@current_index - 1) % @pages.size
        show_index i
      end
    end
  end
end
