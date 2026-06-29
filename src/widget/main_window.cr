require "./box"
require "./dock_widget"

module Crysterm
  class Widget
    # Application main window, modeled after Qt's `QMainWindow`.
    #
    # Arranges, in the conventional layout: a `#menu_bar` and `#tool_bar` across
    # the top, a `#status_bar` across the bottom, dockable panels (`DockWidget`s,
    # added with `#add_dock`) in the left/right/top/bottom dock areas, and the
    # `#central_widget` filling whatever space is left. Everything re-flows to the
    # window's size each frame, so it adapts to terminal resizes.
    #
    # ```
    # win = Widget::MainWindow.new parent: screen, top: 0, left: 0, width: "100%", height: "100%"
    # win.menu_bar = Widget::ListBar.new keys: true, mouse: true
    # win.status_bar = Widget::StatusBar.new
    # win.central_widget = Widget::PlainTextEdit.new
    # win.add_dock Widget::DockWidget.new(title: "Files", area: :left)
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![MainWindow screenshot](../../examples/widget/main_window/main_window-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class MainWindow < Box
      getter menu_bar : Widget?
      getter tool_bar : Widget?
      getter central_widget : Widget?
      getter status_bar : Widget?

      # The docked panels (in all areas, including floating).
      getter docks = [] of DockWidget

      # Rows reserved for the respective bars when present.
      property menu_height : Int32 = 1
      property tool_height : Int32 = 1
      property status_height : Int32 = 1

      # `initialize` is inherited from `Box` unchanged.

      # Defines a `<name>=` setter for one of the singular top-level slots
      # (menu/tool/status bar, central widget): it detaches the slot's previous
      # occupant, stores and appends the new widget, and returns it — the
      # identical body each of these setters previously inlined.
      private macro def_slot_setter(name)
        def {{name.id}}=(w : Widget) : Widget
          @{{name.id}}.try &.remove_from_parent
          @{{name.id}} = w
          append w
          w
        end
      end

      def_slot_setter menu_bar
      def_slot_setter tool_bar
      def_slot_setter status_bar
      def_slot_setter central_widget

      # Adds *dock* (optionally overriding its `#area`) and returns it.
      def add_dock(dock : DockWidget, area : DockWidget::Area? = nil) : DockWidget
        dock.area = area if area
        @docks << dock
        append dock
        dock
      end

      def render(with_children = true)
        relayout
        super
      end

      # Positions every managed slot for the current size. Bars take full-width
      # strips top/bottom; left/right docks span the height between them; top/
      # bottom docks sit within the remaining central column; the central widget
      # fills the rest. Floating docks and hidden widgets are left untouched.
      private def relayout : Nil
        top = (@menu_bar ? @menu_height : 0) + (@tool_bar ? @tool_height : 0)
        bottom = @status_bar ? @status_height : 0
        left = 0
        right = 0

        if mb = @menu_bar
          set_geo mb, top: 0, left: 0, right: 0, height: @menu_height
        end
        if tb = @tool_bar
          # The tool bar sits directly below the menu bar — at the very top when
          # there is no menu bar (otherwise row 0 would be left blank and the tool
          # bar would overlap the central widget, which the `top` accumulator above
          # already places below both bars).
          set_geo tb, top: (@menu_bar ? @menu_height : 0), left: 0, right: 0, height: @tool_height
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
      # `@docks.select` would allocate (relayout calls this four times a frame).
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
