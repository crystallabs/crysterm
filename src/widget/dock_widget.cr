require "./box"

module Crysterm
  class Widget
    # A dockable panel, modeled after Qt's `QDockWidget`.
    #
    # A titled container holding one `#content` widget. Its title bar shows the
    # `#title` plus (when enabled) a float toggle and a close button. A
    # `Widget::MainWindow` arranges docks by their `#area` (`Left`/`Right`/`Top`/
    # `Bottom`); a `Floating` dock is positioned freely and can be dragged by its
    # title bar. Emits `Event::Close` when closed and `Event::Float` (with the new
    # floating state) when floated/re-docked.
    #
    # ```
    # dock = Widget::DockWidget.new title: "Files", area: Widget::DockWidget::Area::Left, dock_size: 24
    # dock.widget = Widget::Tree.new
    # main_window.add_dock dock
    # ```
    class DockWidget < Box
      # Where the dock sits in a `MainWindow` (or `Floating`, positioned freely).
      enum Area
        Left
        Right
        Top
        Bottom
        Floating
      end

      property title : String
      property area : Area

      # Extent along the docking axis: width when docked Left/Right, height when
      # docked Top/Bottom. Ignored while `Floating` (the dock keeps its own size).
      property dock_size : Int32 = 20

      property? closable : Bool = true
      property? floatable : Bool = true

      # The contained widget (Qt's `QDockWidget#widget`). Held in `@dock_content`
      # because `@content` is the base `Widget`'s (textual) content.
      @dock_content : Widget?

      getter! titlebar : Box

      @close_button : Box?
      @float_button : Box?

      # Grab offset captured at the start of a title-bar drag (floating only).
      @drag_dx = 0
      @drag_dy = 0

      def initialize(title = "", area : Area = Area::Left, dock_size = 20, closable = true, floatable = true, **box)
        @title = title
        @area = area
        @dock_size = dock_size
        @closable = closable
        @floatable = floatable

        super **box

        tb = Box.new(
          parent: self, top: 0, left: 0, right: 0, height: 1,
          content: @title, parse_tags: true,
        )
        tb.add_css_class "titlebar" # themed via `.titlebar { ... }`
        @titlebar = tb

        build_buttons
        wire_drag
      end

      def floating? : Bool
        @area.floating?
      end

      # The contained widget, or `nil`.
      def widget : Widget?
        @dock_content
      end

      # Sets (replacing any previous) the dock's content widget, laid out to fill
      # the area below the title bar (Qt's `QDockWidget#setWidget`).
      def widget=(w : Widget) : Widget
        @dock_content.try &.remove_from_parent
        @dock_content = w
        w.top = 1
        w.left = 0
        w.right = 0
        w.bottom = 0
        append w
        request_render
        w
      end

      # Closes the dock: hides it and emits `Event::Close`.
      def close_dock : Nil
        hide
        emit ::Crysterm::Event::Close
        screen?.try &.schedule_render
      end

      # Toggles between `Floating` and the last docked area, emitting
      # `Event::Float` with the new state. A `MainWindow` re-lays-out on the next
      # frame; a floating dock keeps its current position.
      def toggle_floating : Nil
        return unless floatable?
        if floating?
          @area = @prev_area || Area::Left
        else
          @prev_area = @area
          @area = Area::Floating
        end
        refresh_buttons
        emit ::Crysterm::Event::Float, floating?
        screen?.try &.schedule_render
      end

      @prev_area : Area?

      private def build_buttons
        if closable?
          @close_button = btn = Box.new(
            parent: titlebar, top: 0, right: 0, width: 1, height: 1,
            content: "✕", focus_on_click: false,
          )
          btn.add_css_class "titlebutton" # themed via `.titlebutton { ... }`
          btn.on(::Crysterm::Event::Click) { close_dock }
        end
        if floatable?
          @float_button = btn = Box.new(
            parent: titlebar, top: 0, right: (closable? ? 2 : 0), width: 1, height: 1,
            content: "⇕", focus_on_click: false,
          )
          btn.add_css_class "titlebutton" # themed via `.titlebutton { ... }`
          btn.on(::Crysterm::Event::Click) { toggle_floating }
        end
      end

      private def refresh_buttons
        @float_button.try &.set_content(floating? ? "▣" : "⇕")
      end

      # Dragging the title bar moves a *floating* dock (it stays put while docked).
      private def wire_drag
        titlebar.enable_drag reposition: false
        titlebar.on(::Crysterm::Event::DragStart) do |e|
          @drag_dx = e.x - aleft
          @drag_dy = e.y - atop
        end
        titlebar.on(::Crysterm::Event::Drag) do |e|
          next unless floating?
          bound_w = (parent.try(&.awidth) || screen.awidth) - awidth
          bound_h = (parent.try(&.aheight) || screen.aheight) - aheight
          self.left = (e.x - @drag_dx).clamp(0, Math.max(0, bound_w))
          self.top = (e.y - @drag_dy).clamp(0, Math.max(0, bound_h))
          request_render
        end
      end
    end
  end
end
