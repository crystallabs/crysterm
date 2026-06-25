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

      def initialize(**box)
        super **box
      end

      def menu_bar=(w : Widget) : Widget
        @menu_bar.try &.remove_from_parent
        @menu_bar = w
        append w
        w
      end

      def tool_bar=(w : Widget) : Widget
        @tool_bar.try &.remove_from_parent
        @tool_bar = w
        append w
        w
      end

      def status_bar=(w : Widget) : Widget
        @status_bar.try &.remove_from_parent
        @status_bar = w
        append w
        w
      end

      def central_widget=(w : Widget) : Widget
        @central_widget.try &.remove_from_parent
        @central_widget = w
        append w
        w
      end

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
          set_geo tb, top: @menu_height, left: 0, right: 0, height: @tool_height
        end
        if sb = @status_bar
          set_geo sb, bottom: 0, left: 0, right: 0, height: @status_height
        end

        # Left/right docks span the full height between the top and bottom bars.
        active_docks(DockWidget::Area::Left).each do |d|
          set_geo d, top: top, bottom: bottom, left: left, width: d.dock_size
          left += d.dock_size
        end
        active_docks(DockWidget::Area::Right).each do |d|
          set_geo d, top: top, bottom: bottom, right: right, width: d.dock_size
          right += d.dock_size
        end

        # Top/bottom docks sit within the column left after the side docks.
        active_docks(DockWidget::Area::Top).each do |d|
          set_geo d, top: top, left: left, right: right, height: d.dock_size
          top += d.dock_size
        end
        active_docks(DockWidget::Area::Bottom).each do |d|
          set_geo d, bottom: bottom, left: left, right: right, height: d.dock_size
          bottom += d.dock_size
        end

        if cw = @central_widget
          set_geo cw, top: top, bottom: bottom, left: left, right: right
        end
      end

      private def active_docks(area : DockWidget::Area) : Array(DockWidget)
        @docks.select { |d| d.area == area && d.visible? }
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
