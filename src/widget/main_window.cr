require "../layout/dock"
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
    # win = Widget::MainWindow.new parent: window # fills the window by default
    # win.menu_bar.add_menu "File"
    # win.status_bar.show_message "Ready"
    # win.central_widget = Widget::PlainTextEdit.new
    # win.add_tool_bar Widget::ToolBar.new
    # win.add_dock :left, Widget::DockWidget.new(title: "Files")
    # ```
    #
    # Use `#menu_bar?`/`#status_bar?` to ask whether a bar exists without
    # creating one, and assign `nil` to drop a slot.
    #
    # <!-- widget-examples:capture v1 -->
    # ![MainWindow screenshot](../../tests/widget/main_window/main_window.5s.apng)
    # <!-- /widget-examples:capture -->
    class MainWindow < Box
      # A main window fills its window by default — in Qt the `QMainWindow`
      # *is* the window — so `MainWindow.new parent: window` alone is the whole
      # frame. Any geometry passed explicitly still wins. The slots are
      # arranged by the window's own `Carve` engine (installed here).
      def initialize(**box)
        super(**{fill: true}.merge(box))
        self.layout = Carve.new
      end

      # The menu bar, constructed (and parented) on first access — like Qt's
      # `menuBar()`, it never returns null.
      getter menu_bar : MenuBar { (self.menu_bar = MenuBar.new).as(MenuBar) }

      # :ditto:
      getter status_bar : StatusBar { (self.status_bar = StatusBar.new).as(StatusBar) }

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
      # `push` would skip, leaving the bar unrendered.
      def tool_bars : Array(ToolBar)
        @tool_bars.dup
      end

      @docks = [] of DockWidget

      # The docked panels (in all areas, including floating), in the order added.
      # A copy, for the same reason as `#tool_bars`.
      def docks : Array(DockWidget)
        @docks.dup
      end

      # Rows reserved for the menu/status bar when present, and for each tool
      # bar. Live setters: the strips carry the height as their carve hint, so
      # a change re-syncs the hints and repaints.
      getter menu_height : Int32 = 1
      getter tool_height : Int32 = 1
      getter status_height : Int32 = 1

      def menu_height=(value : Int32) : Int32
        @menu_height = value
        @menu_bar.try { |b| b.layout_hint = Layout::Dock::Hint.new(:top, size: value) }
        value
      end

      def tool_height=(value : Int32) : Int32
        @tool_height = value
        @tool_bars.each { |b| b.layout_hint = Layout::Dock::Hint.new(:top, size: value) }
        value
      end

      def status_height=(value : Int32) : Int32
        @status_height = value
        @status_bar.try { |b| b.layout_hint = Layout::Dock::Hint.new(:bottom, size: value) }
        value
      end

      # Defines a `<name>=` setter for one of the singular top-level slots
      # (menu/status bar, central widget): detaches the slot's previous
      # occupant, stores and appends the new widget (stamping the strip's
      # carve hint, when given), and returns it. `nil` clears the slot, so a
      # bar can be taken away again.
      private macro def_slot_setter(name, type, region = nil, size = nil)
        def {{ name.id }}=(w : {{ type.id }}?) : {{ type.id }}?
          @{{ name.id }}.try &.remove_from_parent
          @{{ name.id }} = w
          if w
            append w
            {% if region %}
              w.layout_hint = Layout::Dock::Hint.new({{ region }}, size: {{ size.id }})
            {% end %}
          end
          w
        end
      end

      def_slot_setter menu_bar, MenuBar, :top, @menu_height
      def_slot_setter status_bar, StatusBar, :bottom, @status_height
      def_slot_setter central_widget, Widget

      # Adds *bar* below any tool bars already present (Qt's `addToolBar`), and
      # returns it. Adding the same bar twice is a no-op.
      def add_tool_bar(bar : ToolBar) : ToolBar
        return bar if @tool_bars.includes? bar
        @tool_bars << bar
        append bar
        bar.layout_hint = Layout::Dock::Hint.new(:top, size: @tool_height)
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

      # Qt-name alias of `#add_dock`, symmetric with `#add_tool_bar` (Qt's
      # `QMainWindow#addDockWidget(area, dockwidget)`).
      def add_dock_widget(area : DockWidget::Area, dock : DockWidget) : DockWidget
        add_dock area, dock
      end

      # :ditto: — keeping the dock's own `#area`.
      def add_dock_widget(dock : DockWidget) : DockWidget
        add_dock dock
      end

      # Qt-name alias of `#remove_dock` (Qt's `QMainWindow#removeDockWidget`).
      def remove_dock_widget(dock : DockWidget) : Nil
        remove_dock dock
      end

      # Yields each tool bar in add order (no per-frame `Array` copy).
      protected def each_tool_bar(&) : Nil
        @tool_bars.each { |t| yield t }
      end

      # Whether *w* is one of the tool bars.
      protected def tool_bar?(w : Widget) : Bool
        @tool_bars.includes? w
      end

      # The main window's own `Layout::Dock` variant: the same edge-consuming
      # carve, in `QMainWindow`'s two-tier order — bar strips first (menu and
      # tool bars down from the top, status bar across the bottom), then
      # left/right docks spanning the height between them, then top/bottom
      # docks within the remaining column, the central widget filling the
      # rest. Slots are classified by identity (bars, central) and by their
      # `Layout::Dock::Hint` (docks); everything else — a floating dock is
      # `layout_chrome`, painted on top at its own coordinates — renders
      # unarranged, like under `Layout::Manual`. Being a real engine,
      # `#spacing`, hidden-slot vacancy and margin boxes all apply.
      class Carve < Layout::Dock
        @bars_top = [] of Widget
        @bars_bottom = [] of Widget
        @side_left = [] of Widget
        @side_right = [] of Widget
        @band_top = [] of Widget
        @band_bottom = [] of Widget
        @middle = [] of Widget
        @unmanaged = [] of Widget

        def arrange(container : Widget, interior : RenderedGeometry) : Nil
          # Installed only on a `MainWindow` (its constructor); the type guard
          # (not a cast) keeps the method compilable for every concrete
          # container type `render_children` may pass.
          return unless container.is_a?(MainWindow)
          win = container
          x0 = 0
          y0 = 0
          x1 = interior.width
          y1 = interior.height
          @sp_h = clamped_spacing @spacing, x1
          @sp_v = clamped_spacing @spacing, y1

          @bars_top.clear
          @bars_bottom.clear
          @side_left.clear
          @side_right.clear
          @band_top.clear
          @band_bottom.clear
          @middle.clear
          @unmanaged.clear

          # Bar strips, in slot order (menu above tool bars regardless of
          # append order).
          menu = win.menu_bar?
          status = win.status_bar?
          central = win.central_widget
          @bars_top << menu if menu && slot_occupies?(win, menu)
          win.each_tool_bar { |tb| @bars_top << tb if slot_occupies?(win, tb) }
          @bars_bottom << status if status && slot_occupies?(win, status)

          # Docks (by hint region), the central widget, and free children.
          each_occupying container do |el|
            next if el.same?(menu) || el.same?(status) || win.tool_bar?(el)
            if el.same?(central)
              @middle << el
            elsif h = el.layout_hint.as?(Hint)
              case h.region
              in .left?   then @side_left << el
              in .right?  then @side_right << el
              in .top?    then @band_top << el
              in .bottom? then @band_bottom << el
              in .center? then @middle << el
              end
            else
              @unmanaged << el
            end
          end

          x0, y0, x1, y1 = consume_edge @bars_top, :top, x0, y0, x1, y1
          x0, y0, x1, y1 = consume_edge @bars_bottom, :bottom, x0, y0, x1, y1
          x0, y0, x1, y1 = consume_edge @side_left, :left, x0, y0, x1, y1
          x0, y0, x1, y1 = consume_edge @side_right, :right, x0, y0, x1, y1
          x0, y0, x1, y1 = consume_edge @band_top, :top, x0, y0, x1, y1
          x0, y0, x1, y1 = consume_edge @band_bottom, :bottom, x0, y0, x1, y1

          @middle.each do |el|
            cw = margin_box(x1 - x0, el.mhorizontal)
            ch = margin_box(y1 - y0, el.mvertical)
            place_child el, x0, y0, cw, ch
            render_child el
          end

          # Unmanaged children keep their own geometry (`Layout::Manual`
          # semantics), so a plain child of the main window still renders
          # where it put itself.
          @unmanaged.each { |el| render_child el }
        end

        # Whether a bar slot takes a strip this frame: still parented here and
        # not `#vacant?` (hidden without `retain_size_when_hidden`).
        private def slot_occupies?(win : MainWindow, el : Widget) : Bool
          (el.parent.try &.same?(win)) == true && !vacant?(el)
        end
      end
    end
  end
end
