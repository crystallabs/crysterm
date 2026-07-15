require "./box"
require "./dock_widget"

module Crysterm
  class Widget
    # Application main window, modeled after Qt's `QMainWindow`.
    #
    # Arranges, in the conventional layout: a `#menu_bar` and any `#tool_bars`
    # across the top, a `#status_bar` across the bottom, dockable panels
    # (`DockWidget`s, added with `#add_dock`) in the left/right/top/bottom dock
    # areas, and the `#central_widget` filling whatever space is left. Everything
    # re-flows to the window's size each frame, so it adapts to terminal resizes.
    #
    # `#menu_bar` and `#status_bar` construct themselves on first use, so Qt's
    # canonical idiom works on a bare main window with no setup:
    #
    # ```
    # win = Widget::MainWindow.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
    # win.menu_bar.add_menu "File"
    # win.status_bar.show_message "Ready"
    # win.central_widget = Widget::PlainTextEdit.new
    # win.add_tool_bar Widget::ToolBar.new
    # win.add_dock Widget::DockWidget::Area::Left, Widget::DockWidget.new(title: "Files")
    # ```
    #
    # Use `#menu_bar?`/`#status_bar?` to ask whether a bar exists without
    # creating one, and assign `nil` to drop a slot.
    #
    # <!-- widget-examples:capture v1 -->
    # ![MainWindow screenshot](../../tests/widget/main_window/main_window.5s.apng)
    # <!-- /widget-examples:capture -->
    class MainWindow < Box
      # The menu bar, constructed (and parented) on first access — Qt's
      # `menuBar()` never returns null, which is what makes `win.menu_bar.add_menu "File"`
      # the one-liner it is. The declared type is the concrete `MenuBar`, not a
      # bare `Widget`: a `Widget?` slot meant even a correctly-assigned bar
      # needed a cast before any of its own methods would compile.
      getter menu_bar : MenuBar { MenuBar.new(parent: self) }

      # :ditto:
      getter status_bar : StatusBar { StatusBar.new(parent: self) }

      # The menu bar, or `nil` if none has been created — the non-constructing
      # question `#menu_bar` can't ask.
      def menu_bar? : MenuBar?
        @menu_bar
      end

      # :ditto:
      def status_bar? : StatusBar?
        @status_bar
      end

      # The widget filling the space left by the bars and docks. Unlike the bars,
      # this is not auto-created (nor is it in Qt): there is no sensible default
      # central widget.
      getter central_widget : Widget?

      @tool_bars = [] of ToolBar

      # The tool bars, top to bottom in the order added. A copy — mutate via
      # `#add_tool_bar`/`#remove_tool_bar`, which also do the parenting a bare
      # `push` here would skip, leaving the bar unrendered.
      def tool_bars : Array(ToolBar)
        @tool_bars.dup
      end

      @docks = [] of DockWidget

      # The docked panels (in all areas, including floating), in the order added.
      # A copy, for the same reason as `#tool_bars`.
      def docks : Array(DockWidget)
        @docks.dup
      end

      # Rows reserved for the menu/status bar when present, and for each tool bar.
      property menu_height : Int32 = 1
      property tool_height : Int32 = 1
      property status_height : Int32 = 1

      # `initialize` is inherited from `Box` unchanged.

      # Defines a `<name>=` setter for one of the singular top-level slots
      # (menu/status bar, central widget): it detaches the slot's previous
      # occupant, stores and appends the new widget, and returns it — the
      # identical body shared by each of these setters. `nil` just clears the
      # slot, so a bar can be taken away again.
      private macro def_slot_setter(name, type)
        def {{name.id}}=(w : {{type.id}}?) : {{type.id}}?
          @{{name.id}}.try &.remove_from_parent
          @{{name.id}} = w
          append w if w
          w
        end
      end

      def_slot_setter menu_bar, MenuBar
      def_slot_setter status_bar, StatusBar
      def_slot_setter central_widget, Widget

      # Adds *bar* below any tool bars already present (Qt's `addToolBar`), and
      # returns it. Adding the same bar twice is a no-op.
      def add_tool_bar(bar : ToolBar) : ToolBar
        return bar if @tool_bars.includes? bar
        @tool_bars << bar
        append bar
        bar
      end

      # Removes *bar*, detaching (not destroying) it (Qt's `removeToolBar`).
      def remove_tool_bar(bar : ToolBar) : Nil
        return unless @tool_bars.delete bar
        remove bar
      end

      # Adds *dock* to the *area* (overriding the dock's own `#area`) and returns
      # it. Argument order is Qt's `addDockWidget(area, dockwidget)`.
      def add_dock(area : DockWidget::Area, dock : DockWidget) : DockWidget
        dock.area = area
        add_dock dock
      end

      # :ditto: — keeping the dock's own `#area`. Adding the same dock twice is a
      # no-op.
      def add_dock(dock : DockWidget) : DockWidget
        return dock if @docks.includes? dock
        @docks << dock
        append dock
        dock
      end

      # Removes *dock*, detaching (not destroying) it (Qt's `removeDockWidget`).
      def remove_dock(dock : DockWidget) : Nil
        return unless @docks.delete dock
        remove dock
      end

      def render(with_children = true)
        relayout
        super
      end

      # Positions every managed slot for the current size. The menu bar and the
      # tool bars stack in full-width strips down from the top, the status bar
      # takes one across the bottom; left/right docks span the height between
      # them; top/bottom docks sit within the remaining central column; the
      # central widget fills the rest. Floating docks and hidden widgets are left
      # untouched.
      #
      # Reads `@menu_bar`/`@status_bar` (not `#menu_bar`/`#status_bar`) so laying
      # out never *constructs* the bars it is asking about.
      private def relayout : Nil
        top = 0
        bottom = @status_bar ? @status_height : 0
        left = 0
        right = 0

        if mb = @menu_bar
          set_geo mb, top: top, left: 0, right: 0, height: @menu_height
          top += @menu_height
        end
        # Each tool bar sits below the previous one, the first directly below the
        # menu bar — or at the very top if there is none.
        @tool_bars.each do |tb|
          next unless tb.visible?
          set_geo tb, top: top, left: 0, right: 0, height: @tool_height
          top += @tool_height
        end
        if sb = @status_bar
          set_geo sb, bottom: 0, left: 0, right: 0, height: @status_height
        end

        # Left/right docks span the full height between the top and bottom bars.
        each_active_dock(DockWidget::Area::Left) do |d|
          set_geo d, top: top, bottom: bottom, left: left, width: d.dock_size
          left += d.dock_size
        end
        each_active_dock(DockWidget::Area::Right) do |d|
          set_geo d, top: top, bottom: bottom, right: right, width: d.dock_size
          right += d.dock_size
        end

        # Top/bottom docks sit within the column left after the side docks.
        each_active_dock(DockWidget::Area::Top) do |d|
          set_geo d, top: top, left: left, right: right, height: d.dock_size
          top += d.dock_size
        end
        each_active_dock(DockWidget::Area::Bottom) do |d|
          set_geo d, bottom: bottom, left: left, right: right, height: d.dock_size
          bottom += d.dock_size
        end

        if cw = @central_widget
          set_geo cw, top: top, bottom: bottom, left: left, right: right
        end
      end

      # Yields each visible dock in *area* without the per-frame `Array` a
      # `@docks.select` would allocate.
      private def each_active_dock(area : DockWidget::Area, &)
        @docks.each do |d|
          yield d if d.area == area && d.visible?
        end
      end

      # Sets a child's geometry, clearing the dimensions not given so stale
      # anchors from a previous layout can't fight the new ones.
      private def set_geo(w : Widget, top = nil, bottom = nil, left = nil, right = nil, width = nil, height = nil) : Nil
        w.top = top
        w.bottom = bottom
        w.left = left
        w.right = right
        w.width = width
        w.height = height
      end
    end
  end
end
