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
    # tabs.tab_bar.focus # so the arrow keys switch tabs
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![TabWidget screenshot](../../tests/widget/tab_widget/tab_widget.5s.apng)
    # <!-- /widget-examples:capture -->
    class TabWidget < Box
      include Mixin::PagedContainer
      include Mixin::SubStyle
      include Mixin::WindowLifecycle

      # Where the tab bar sits relative to the pages (Qt's `QTabWidget::North` /
      # `South`). Qt's `West`/`East` have no counterpart here: the widget splits
      # along the horizontal only, so a side bar would be a layout change.
      enum Position
        Top
        Bottom
      end

      # The tab bar. (Built in `initialize` after `super`, hence `getter!`.)
      getter! tab_bar : ListBar

      # The tab titles, parallel to `#pages`. A copy: the live array backs the
      # bar's items, so mutating it directly would leave the two out of sync
      # (retitle via `#set_tab_text`, add/remove via `#add_tab`/`#remove_tab`).
      def tab_titles : Array(String)
        @tab_titles.dup
      end

      @tab_titles = [] of String

      # Height (in rows) reserved for the tab bar.
      #
      # Not a bare `property`: the bar's geometry and every page's inset bake
      # this in, so a runtime change must re-lay both out (the constructor
      # assigns the ivar directly, before the bar exists).
      getter tab_height : Int32 = 1

      # :ditto:
      def tab_height=(value : Int32) : Int32
        return value if value == @tab_height
        @tab_height = value
        relayout_tab_chrome
        value
      end

      # Where the tab bar is placed.
      #
      # Not a bare `property`: see `#tab_height=`.
      getter tab_position : Position = :top

      # :ditto:
      def tab_position=(value : Position) : Position
        return value if value == @tab_position
        @tab_position = value
        relayout_tab_chrome
        value
      end

      # Re-pins the bar to the current `tab_position`/`tab_height` — clearing
      # the opposite anchor, so the bar isn't left over-constrained with both
      # `top` and `bottom` set — and re-insets every page to match.
      private def relayout_tab_chrome : Nil
        bar = tab_bar
        bar.top = @tab_position.top? ? 0 : nil
        bar.bottom = @tab_position.bottom? ? 0 : nil
        bar.height = @tab_height
        @pages.each { |p| layout_page p }
        request_render
      end

      # Whether tabs show a `✕` marker and can be closed.
      #
      # Not a bare `property?`: the `✕` marker is baked into each bar item's
      # TEXT only when titles are (re)built (`#display_title`, called from
      # `#add_tab`/`#rebuild_bar`), while the click/Delete handlers that act on
      # it read the flag live — so a bare-ivar toggle would desync the display
      # from the behavior (matching `#tab_height=`/`#tab_position=` above,
      # converted for the same reason).
      getter? tabs_closable : Bool = false

      # :ditto:
      def tabs_closable=(value : Bool) : Bool
        return value if value == @tabs_closable
        @tabs_closable = value
        refresh_bar_titles
        value
      end

      # Whether the current tab can be reordered with `<`/`>`.
      property? movable : Bool = false

      # When set, the widget behaves as a *carousel*: it auto-advances to the
      # next tab every interval, wrapping at the end. `nil` disables it.
      getter auto_advance : Time::Span?

      # The running auto-advance timer, if any.
      @carousel_timer : FrameClock?

      # Guards against the bar↔page selection feedback loop.
      @switching = false

      def initialize(tab_height = 1, tab_position : Position = :top, tabs_closable = false, movable = false,
                     @auto_advance : Time::Span? = nil, **box)
        @tab_height = tab_height
        @tab_position = tab_position
        @tabs_closable = tabs_closable
        @movable = movable

        super **box

        @tab_bar = ListBar.new(
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
        tab_bar.on(::Crysterm::Event::ItemSelected) do |e|
          self.current_index = e.index unless @switching
        end

        # Wheel over the bar's free cells cycles tabs; a wheel over a tab *item*
        # is handled per item, since mouse events don't bubble.
        tab_bar.on(::Crysterm::Event::Mouse) { |e| wheel_cycle e }

        # Close (Delete) and reorder (`<`/`>`) the current tab from the bar.
        tab_bar.on(::Crysterm::Event::KeyPress) do |e|
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

        # Push any `TabWidget::tab`/`::pane` styling onto tabs/current page each
        # frame. PreRender fires after the cascade and before children draw, so
        # it lands even though they snapshot style once.
        on(::Crysterm::Event::PreRender) { sync_tab_style }

        # Carousel auto-advance: start once attached to a window (the timer needs
        # one), and stop on destroy so it doesn't poke a dead widget. Also stop on
        # a plain detach (`remove` without `destroy`): otherwise the `FrameClock`
        # timer keeps firing `next_page` on the now-windowless widget forever,
        # pinning it alive via the closure. A later re-attach re-arms via `Attached`.
        wire_window_lifecycle destroy: true
      end

      # The carousel timer lives with the window: (re)start on attach, stop on
      # detach/destroy.
      private def on_attach_window : Nil
        start_carousel
      end

      # :ditto:
      private def on_detach_window : Nil
        stop_carousel
      end

      # Applies the `TabWidget::tab` (Qt's `QTabBar::tab`) and `TabWidget::pane`
      # (`QTabWidget::pane`) sub-styles onto the bar's tabs and the current page.
      # With no matching rule each push is a no-op, keeping the default look.
      private def sync_tab_style : Nil
        tab_bar.item_boxes.each { |it| apply_substyle it, style.tab }

        # `::pane` styles the current page itself, since it fills the pane region.
        apply_substyle current_widget, style.pane
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
        @carousel_timer = scr.every(span) { next_page }
      end

      private def stop_carousel : Nil
        @carousel_timer.try &.stop
        @carousel_timer = nil
      end

      # Wires *item* (a tab's bar box) so a click on its right-most two cells —
      # where the `✕` is drawn — closes the tab instead of selecting it.
      # Accepting the `Event::Mouse` suppresses the follow-up `Event::Click`.
      private def wire_close(item : Widget) : Nil
        item.on(::Crysterm::Event::Mouse) do |e|
          next if wheel_cycle e
          next unless tabs_closable? && e.action.down?
          # No close mark drawn (`::close-button { glyph: none }`) — nothing to
          # click; without this guard the last two cells would still close.
          next unless close_glyph
          next unless i = tab_bar.item_boxes.index(item)
          if e.x >= item.aleft + item.awidth - 2 && e.x < item.aleft + item.awidth
            close_tab i
            e.accept
          end
        rescue
          # Item not laid out yet — ignore.
        end
      end

      # The close mark appended to a closable tab: CSS
      # `TabWidget::close-button { glyph: … }`, then the registry; `nil` when
      # the stylesheet says `glyph: none` (tabs close via keyboard/API only).
      private def close_glyph : Char?
        glyph?(Glyphs::Role::CloseButton, style.raw_sub_style("close-button"))
      end

      # The title as shown in the bar (with a `✕` appended when closable).
      private def display_title(title : String) : String
        return title unless tabs_closable?
        close_glyph.try { |c| return "#{title} #{c}" }
        title
      end

      # Re-points every tab command's callback at its current index: commands
      # capture an absolute index when added, which goes stale after a tab is
      # removed or reordered. Callers wrap it in `@switching`.
      private def repoint_tab_callbacks : Nil
        @tab_titles.each_with_index do |_, i|
          tab_bar.commands[i].callback = -> { self.current_index = i }
        end
      end

      # Rebuilds the bar's items from `@tab_titles` after an insert or a reorder,
      # re-pointing the (index-capturing) commands and re-wiring the `✕` cells on
      # the freshly created item boxes. Suppresses the bar's own `ItemSelected`
      # while it churns, so it can't drive a page switch mid-rebuild.
      private def rebuild_bar : Nil
        @switching = true
        tab_bar.items = @tab_titles.map { |t| display_title t }
        repoint_tab_callbacks
        @switching = false
        tab_bar.item_boxes.each { |it| wire_close it }
      end

      # Appends a tab titled *title* whose body is *page*, sized to fill the
      # area beside the tab bar. The first tab added becomes current.
      def add_tab(title : String, page : Widget) : self
        @tab_titles << title
        @pages << page

        layout_page page
        append page

        index = @pages.size - 1

        # Suppress the bar's `ItemSelected` (emitted by its own first-item
        # `selected = 0`) while adding, so it can't drive a page switch before the
        # visibility bookkeeping below runs.
        @switching = true
        tab_bar.add_item(display_title title) { self.current_index = index }
        @switching = false
        tab_bar.item_boxes.last?.try { |it| wire_close it }

        register_page page
        self
      end

      # Inserts a tab titled *title* whose body is *page* at *index* (clamped to
      # the end), like Qt's `insertTab`; returns the index it landed at. The page
      # that was current stays current, following its shift.
      def insert_tab(index : Int, title : String, page : Widget) : Int32
        i = index.clamp(0, @pages.size)
        cur = current_widget

        @tab_titles.insert i, title
        @pages.insert i, page
        layout_page page
        append page

        # An insert renumbers every tab at/after *i*, so the bar's items and
        # their index-capturing commands must be rebuilt wholesale — there is no
        # "insert one item" on the bar that keeps the rest pointing right.
        rebuild_bar

        if cur
          page.hide
          # `-1` first: the previously-current page may still sit at the same
          # index (an insert after it), and `#show_index` no-ops on the current
          # one — which would leave the bar highlighting the wrong tab.
          @current_index = -1
          self.current_index = @pages.index(cur) || i
        else
          register_page page
        end
        i
      end

      # The title of the tab at *index*, or `nil` when out of range (Qt's `tabText`).
      def tab_text(index : Int) : String?
        return if index < 0
        @tab_titles[index]?
      end

      # Retitles the tab at *index* (Qt's `setTabText`); out of range is a no-op.
      def set_tab_text(index : Int, title : String) : Nil
        return unless 0 <= index < @tab_titles.size
        return if @tab_titles[index] == title
        @tab_titles[index] = title
        # A title sets its bar item's width, and hence every later item's offset,
        # so the bar is rebuilt wholesale rather than poking one box's content.
        refresh_bar_titles
      end

      # Rebuilds the bar's items (re-deriving each title through
      # `#display_title`, so a `#tabs_closable=` toggle is picked up too) and
      # restores the current-tab highlight, which a rebuild resets. Shared by
      # `#set_tab_text` and `#tabs_closable=`.
      private def refresh_bar_titles : Nil
        rebuild_bar
        @switching = true
        tab_bar.current_index = @current_index if @current_index >= 0
        @switching = false
        request_render
      end

      # Positions *page* to fill the widget beside the tab bar.
      private def layout_page(page : Widget) : Nil
        if @tab_position.top?
          stretch_child page, top: @tab_height, bottom: 0
        else
          stretch_child page, top: 0, bottom: @tab_height
        end
      end

      # Mirrors the new selection in the bar without re-triggering its
      # `ItemSelected` handler.
      protected def after_show_index(index : Int) : Nil
        unless tab_bar.current_index == index
          @switching = true
          tab_bar.current_index = index
          @switching = false
        end
      end

      # Removes the tab at *index*, detaching (not destroying) its page and
      # returning it — like Qt's `removeTab`. Keeps a valid current tab and
      # emits `Event::ItemRemoved`.
      def remove_tab(index : Int) : Widget?
        return unless 0 <= index < @pages.size

        # Removing a *non-current* tab must not switch the visible page (Qt's
        # `removeTab` keeps the current page current) — remember it so it can be
        # re-shown at its new index below.
        cur = current_widget
        page = @pages.delete_at index
        @tab_titles.delete_at index

        @switching = true
        tab_bar.remove_item index
        # Remaining commands' captured indices go stale after removal; re-point
        # them or Enter on a tab past the removed one jumps to the wrong page.
        repoint_tab_callbacks
        @switching = false

        remove page

        # Re-point current_index at a still-existing tab and show it: the page
        # that was current stays current when it survived the removal; only
        # removing the current tab itself falls back to its neighbor.
        reclamp_after_removal index, cur

        emit ::Crysterm::Event::ItemRemoved
        request_render
        page
      end

      # Catches a managed page detached by any path other than `#remove_tab` — a
      # direct `page.destroy` or `#detach_from_tree` (both land here via
      # `parent.remove(self)`), a bare `#remove`, or a reparenting append — and
      # runs the same teardown so `@pages`/`@tab_titles`/the bar never point at a
      # gone page. `#remove_tab` deletes the page from `@pages` *before* it calls
      # `remove page`, so on that path the guard below is already false and it
      # does the work itself (mirrors `Splitter#remove_widget`); the tab bar and
      # any other non-page child pass straight through.
      def remove(element)
        idx = @pages.index element
        # Snapshot the current page before the delete so the reclamp can keep it
        # current when it wasn't the one removed.
        cur = current_widget
        super
        if idx
          @tab_titles.delete_at idx
          @pages.delete_at idx
          @switching = true
          tab_bar.remove_item idx
          # Surviving commands' captured indices go stale after removal; re-point
          # them or Enter on a later tab jumps to the wrong page.
          repoint_tab_callbacks
          @switching = false
          reclamp_after_removal idx, cur
          emit ::Crysterm::Event::ItemRemoved
          request_render
        end
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

        current = current_widget

        @pages.insert to, @pages.delete_at(from)
        @tab_titles.insert to, @tab_titles.delete_at(from)

        # Rebuild the bar from the reordered titles.
        rebuild_bar

        # Restore the previously-current page as current. `-1` first: it usually
        # lands on a *different* index, but not always, and `#show_index` no-ops
        # on the current one — which would leave the bar's highlight behind.
        @current_index = -1
        if current && (i = @pages.index current)
          self.current_index = i
        else
          self.current_index = to
        end
      end

      # Cycles tabs on a wheel notch over the bar — down/up, both wrapping,
      # matching a browser tab strip. Returns whether it consumed the notch.
      # Accepting the event suppresses the window's default scroll-the-view.
      private def wheel_cycle(e : ::Crysterm::Event::Mouse) : Bool
        if e.action.wheel_down?
          next_page
        elsif e.action.wheel_up?
          previous_page
        else
          return false
        end
        e.accept
        true
      end
    end
  end
end
