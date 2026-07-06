require "./box"
require "./listbar"
require "../mixin/paged_container"
require "../mixin/sub_style"

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
    # tabs = Widget::TabWidget.new parent: window, width: 60, height: 20, tabs_closable: true
    # tabs.add_tab "Files", Widget::Box.new(content: "...")
    # tabs.add_tab "Edit", Widget::Box.new(content: "...")
    # tabs.bar.focus # so the arrow keys switch tabs
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![TabWidget screenshot](../../tests/widget/tab_widget/tab_widget.5s.apng)
    # <!-- /widget-examples:capture -->
    class TabWidget < Box
      # `#pages`, `#current_index`, `#current_page` and the show/next/previous
      # core (raise one page, hide the rest) come from here.
      include Mixin::PagedContainer
      # `#apply_substyle`, used by `#sync_tab_style`.
      include Mixin::SubStyle
      # Carousel timer install/teardown across the window lifecycle.
      include Mixin::WindowLifecycle

      # Where the tab bar sits relative to the pages (Qt's `QTabWidget::North` /
      # `South`).
      enum Position
        Top
        Bottom
      end

      # The tab bar. (Built in `initialize` after `super`, hence `getter!`.)
      getter! bar : ListBar

      # The tab titles, parallel to `#pages`.
      getter tab_titles = [] of String

      # Height (in rows) reserved for the tab bar.
      property tab_height : Int32 = 1

      # Where the tab bar is placed.
      property tab_position : Position = :top

      # Whether tabs show a `✕` marker and can be closed.
      property? tabs_closable : Bool = false

      # Whether the current tab can be reordered with `<`/`>`.
      property? movable : Bool = false

      # When set, the widget behaves as a *carousel* (à la blessed-contrib's
      # `carousel`): it auto-advances to the next tab every interval, wrapping at
      # the end. `nil` disables it. Set via the constructor or `#auto_advance=`.
      getter auto_advance : Time::Span?

      # The running auto-advance timer, if any.
      @carousel_timer : FrameClock?

      # Guards against the bar↔page selection feedback loop (see `#show_tab`).
      @switching = false

      def initialize(tab_height = 1, tab_position : Position = :top, tabs_closable = false, movable = false,
                     @auto_advance : Time::Span? = nil, **box)
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

        # Wheel over the bar's free cells cycles tabs (a wheel over a tab *item*
        # is handled per item in `#wire_close`, since mouse events don't bubble).
        bar.on(::Crysterm::Event::Mouse) { |e| wheel_cycle e }

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

        # Closing via the `✕` marker is wired per tab-item in `#wire_close`: each
        # item box is itself the topmost widget under the pointer, so the click's
        # `Event::Mouse` is delivered to the item, not the bar (no bubbling).

        # Push any `TabWidget::tab`/`::pane` styling onto tabs/current page each
        # frame (see `#sync_tab_style`). PreRender fires after the cascade and
        # before children draw, so it lands even though they snapshot style once.
        on(::Crysterm::Event::PreRender) { sync_tab_style }

        # Carousel auto-advance: start once attached to a window (the timer needs
        # one), and stop on destroy so it doesn't poke a dead widget. Also stop on
        # a plain detach (`remove` without `destroy`): otherwise the `FrameClock`
        # timer keeps firing `next_tab` on the now-windowless widget forever,
        # pinning it alive via the closure. A later re-attach re-arms via `Attach`.
        # Starts now too, in case we are already on a window (parent: window).
        wire_window_lifecycle destroy: true
      end

      # The carousel timer lives with the window: (re)start on attach, stop on
      # detach/destroy (see `Mixin::WindowLifecycle`).
      private def on_attach_window : Nil
        start_carousel
      end

      # :ditto:
      private def on_detach_window : Nil
        stop_carousel
      end

      # Applies the `TabWidget::tab` (Qt's `QTabBar::tab`) and `TabWidget::pane`
      # (`QTabWidget::pane`) sub-styles onto the bar's tabs and the current page.
      # Each push is guarded by `same?`: no matching rule falls back to the
      # widget's own style, a no-op, keeping the default look unchanged.
      private def sync_tab_style : Nil
        # `apply_substyle` `dup`s the sub-style per child, so the current page's
        # copy can't be mutated (`show`/`hide`'s `visible`) and leak into the next.
        bar.items.each { |it| apply_substyle it, style.tab }

        # `::pane` styles the current page itself, since it fills the pane region.
        apply_substyle current_page, style.pane
      end

      # Sets the carousel interval, (re)starting or stopping the timer. `nil`
      # turns auto-advance off.
      def auto_advance=(span : Time::Span?) : Time::Span?
        @auto_advance = span
        stop_carousel
        start_carousel
        span
      end

      # Starts the auto-advance timer if an interval is set and a window is
      # available. Idempotent (drops any prior timer first).
      private def start_carousel : Nil
        stop_carousel
        span = @auto_advance
        return unless span
        scr = window?
        return unless scr
        @carousel_timer = scr.every(span) { next_tab }
      end

      private def stop_carousel : Nil
        @carousel_timer.try &.stop
        @carousel_timer = nil
      end

      # Wires *item* (a tab's bar box) so a click on its right-most two cells —
      # where `display_title` puts the `✕` — closes the tab instead of selecting
      # it. Accepting the `Event::Mouse` suppresses the follow-up `Event::Click`.
      private def wire_close(item : Widget) : Nil
        item.on(::Crysterm::Event::Mouse) do |e|
          next if wheel_cycle e
          next unless tabs_closable? && e.action.down?
          next unless i = bar.items.index(item)
          if e.x >= item.aleft + item.awidth - 2 && e.x < item.aleft + item.awidth
            close_tab i
            e.accept
          end
        rescue
          # Item not laid out yet — ignore.
        end
      end

      # The title as shown in the bar (with a `✕` appended when closable).
      private def display_title(title : String) : String
        tabs_closable? ? "#{title} ✕" : title
      end

      # Re-points every tab command's callback at its current index: commands
      # capture an absolute index when added (`bar.add … { show_tab index }`),
      # which goes stale after a tab is removed/reordered. Callers wrap it in
      # `@switching`.
      private def repoint_tab_callbacks : Nil
        @tab_titles.each_with_index do |_, i|
          bar.commands[i].callback = -> { show_tab i }
        end
      end

      # Appends a tab titled *title* whose body is *page*, sized to fill the
      # area beside the tab bar. The first tab added becomes current.
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
        bar.items.last?.try { |it| wire_close it }

        register_page page
        self
      end

      # Positions *page* to fill the widget beside the tab bar.
      private def layout_page(page : Widget) : Nil
        if @tab_position.top?
          fill_parent page, top: @tab_height, bottom: 0
        else
          fill_parent page, top: 0, bottom: @tab_height
        end
      end

      # Raises the page (and selects the tab) at *index*, hiding the others.
      def show_tab(index : Int) : Nil
        show_index index
      end

      # Mirrors the new selection in the bar without re-triggering its
      # `SelectItem` handler (see `#initialize`). Runs after `#show_index`.
      protected def after_show_index(index : Int) : Nil
        unless bar.selected == index
          @switching = true
          bar.selekt index
          @switching = false
        end
      end

      # Removes the tab at *index*, detaching (not destroying) its page and
      # returning it — like Qt's `removeTab`. Keeps a valid current tab and
      # emits `Event::RemoveItem`.
      def remove_tab(index : Int) : Widget?
        return nil unless 0 <= index < @pages.size

        page = @pages.delete_at index
        @tab_titles.delete_at index

        @switching = true
        bar.remove_item index
        # Remaining commands' captured indices go stale after removal; re-point
        # them or Enter on a tab past the removed one jumps to the wrong page.
        repoint_tab_callbacks
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

      # Like `#remove_tab`, but also destroys the detached page — the
      # destructive action behind the `✕`/Delete UI.
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
        repoint_tab_callbacks
        @switching = false
        # `set_items` recreated the item boxes, so re-wire their `✕` close cells.
        bar.items.each { |it| wire_close it }

        # Restore the previously-current page as current.
        @current_index = -1
        if current && (i = @pages.index current)
          show_tab i
        else
          show_tab to
        end
      end

      # Cycles tabs on a wheel notch over the bar — down/up, both wrapping,
      # matching a browser tab strip. Returns whether it consumed the notch.
      # Accepting the event suppresses the window's default scroll-the-view.
      private def wheel_cycle(e : ::Crysterm::Event::Mouse) : Bool
        if e.action.wheel_down?
          next_tab
        elsif e.action.wheel_up?
          previous_tab
        else
          return false
        end
        e.accept
        true
      end

      # Selects the next tab (wrapping at the end).
      def next_tab : Nil
        next_index
      end

      # Selects the previous tab (wrapping at the start).
      def previous_tab : Nil
        previous_index
      end
    end
  end
end
