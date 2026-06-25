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
    #
    # <!-- widget-examples:capture v1 -->
    # ![TabWidget screenshot](../../examples/widget/tab_widget/tab_widget-capture5s.apng)
    # <!-- /widget-examples:capture -->
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

      # When set, the widget behaves as a *carousel* (à la blessed-contrib's
      # `carousel`): it auto-advances to the next tab every interval, wrapping at
      # the end. `nil` disables it. Set via the constructor or `#auto_advance=`.
      getter auto_advance : Time::Span?

      # The running auto-advance timer, if any.
      @carousel_timer : Animation?

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
        # `Event::Mouse` is delivered to the *item*, not to the bar (mouse events
        # don't bubble) — a bar-level handler would never see clicks on a tab.

        # Push any `TabWidget::tab`/`::pane` styling onto the tabs/current page
        # each frame (see `#sync_tab_style`). PreRender fires after the cascade and
        # before the bar/page (children) draw, so it lands even though they snapshot
        # their style when first created.
        on(::Crysterm::Event::PreRender) { sync_tab_style }

        # Carousel auto-advance: start once attached to a screen (the timer needs
        # one), and stop on destroy so it doesn't poke a dead widget.
        on(::Crysterm::Event::Attach) { start_carousel }
        on(::Crysterm::Event::Destroy) { stop_carousel }
        start_carousel # in case we are already on a screen (parent: screen)
      end

      # Applies the `TabWidget::tab` (Qt's `QTabBar::tab`) and `TabWidget::pane`
      # (`QTabWidget::pane`) sub-styles onto the bar's tabs and the current page.
      # Each push is guarded by `same?`: when no such rule matched, the sub-style
      # falls back to the widget's own style and that push is a no-op — so the
      # default look is unchanged. (`::pane` styles the *current page itself*,
      # since the page fills the pane region; an explicit `::pane` rule therefore
      # overrides that page's normal style for the area beside the bar.)
      private def sync_tab_style : Nil
        tab = style.tab
        bar.items.each(&.styles.normal=(tab)) unless tab.same?(style)

        pane = style.pane
        unless pane.same?(style)
          current_page.try(&.styles.normal=(pane))
        end
      end

      # Sets the carousel interval, (re)starting or stopping the timer. `nil`
      # turns auto-advance off.
      def auto_advance=(span : Time::Span?) : Time::Span?
        @auto_advance = span
        stop_carousel
        start_carousel
        span
      end

      # Starts the auto-advance timer if an interval is set and a screen is
      # available. Idempotent (drops any prior timer first).
      private def start_carousel : Nil
        stop_carousel
        span = @auto_advance
        return unless span
        scr = screen?
        return unless scr
        @carousel_timer = scr.every(span) { next_tab }
      end

      private def stop_carousel : Nil
        @carousel_timer.try &.stop
        @carousel_timer = nil
      end

      # Wires *item* (a tab's bar box) so a click on its right-most two cells —
      # where `display_title` puts the `✕` (one cell in from the edge, since the
      # bar centers the text) — closes the corresponding tab instead of selecting
      # it. Accepting the `Event::Mouse` suppresses the follow-up `Event::Click`
      # that would otherwise switch to the tab.
      private def wire_close(item : Widget) : Nil
        item.on(::Crysterm::Event::Mouse) do |e|
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
        bar.items.last?.try { |it| wire_close it }

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
