require "./box"
require "../mixin/sub_style"

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
    #
    # <!-- widget-examples:capture v1 -->
    # ![DockWidget screenshot](../../tests/widget/dock_widget/dock_widget.5s.apng)
    # <!-- /widget-examples:capture -->
    class DockWidget < Box
      # `#apply_substyle`, used by the `PreRender` handler below.
      include Mixin::SubStyle

      # Where the dock sits in a `MainWindow` (or `Floating`, positioned freely).
      enum Area
        Left
        Right
        Top
        Bottom
        Floating
      end

      getter title : String
      property area : Area

      # Updates the stored title and the rendered title-bar text at runtime. A
      # plain `property` left the title-bar content a construction-time snapshot,
      # so `dock.title = "…"` never changed anything on screen.
      def title=(value : String) : String
        @title = value
        @titlebar.try &.set_content(value)
        request_render
        value
      end

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

      # The bottom-right resize grip. Present only on a `#floatable?` dock and
      # shown only while floating (see `#refresh_grip`).
      getter size_grip : SizeGrip?

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
        build_size_grip
        wire_drag
        refresh_buttons # show the glyph matching the initial docked/floating state

        # `DockWidget::title`/`::close-button`/`::float-button { … }` style the
        # title bar and its buttons. Pushed onto each child box every frame after
        # the cascade; guarded by `same?` so a missing rule is a no-op and the
        # elements keep their `.titlebar`/`.titlebutton` theme look. See
        # `Widget::TabWidget#sync_tab_style`.
        on(::Crysterm::Event::PreRender) do
          apply_substyle titlebar, style.title
          # Float/close buttons default to the bar's own colors so they stay
          # legible under any theme instead of rendering as transparent "black
          # holes". An explicit `::close-button`/`::float-button` rule still
          # supplies the base look; only unset colors fall back to the bar.
          sync_titlebutton @close_button, style.close_button
          sync_titlebutton @float_button, style.float_button
          position_grip
        end
      end

      def floating? : Bool
        @area.floating?
      end

      # Structural border at the unstyled floor (see `#floor_border_value` for
      # which sides); under a theme the cascade owns the border instead.
      def floor_border? : Bool
        true
      end

      # A floating dock is an overlay, so it gets a full frame. A docked pane
      # only needs a border on the side facing the content. `#ensure_floor_border`
      # re-syncs this as the dock floats/re-docks (and across `Area` changes).
      def floor_border_value
        return true if floating? # full frame for a detached pane
        case @area
        in .left?     then Border.new(0, 0, 1, 0) # content is to the right
        in .right?    then Border.new(1, 0, 0, 0) # content is to the left
        in .top?      then Border.new(0, 0, 0, 1) # content is below
        in .bottom?   then Border.new(0, 1, 0, 0) # content is above
        in .floating? then true                   # handled above; keep exhaustive
        end
      end

      # The contained widget, or `nil`.
      def widget : Widget?
        @dock_content
      end

      # Sets (replacing any previous) the dock's content widget, laid out to fill
      # the area below the title bar (Qt's `QDockWidget#setWidget`).
      def widget=(w : Widget) : Widget
        @dock_content = replace_content_child @dock_content, w, top: 1
        # Content is appended after the grip, so it would render over the grip's
        # corner cell without this.
        @size_grip.try(&.front!)
        w
      end

      # Closes the dock: hides it and emits `Event::Close`.
      def close_dock : Nil
        hide
        emit ::Crysterm::Event::Close
        window?.try &.schedule_render
      end

      # Toggles between `Floating` and the last docked area, emitting
      # `Event::Float` with the new state. A `MainWindow` re-lays-out on the next
      # frame; a floating dock keeps its current position.
      #
      # `restore` (default true, used by the ⇕ button) puts the dock back at its
      # last floating position/size. The drag-undock path passes `restore: false`
      # so the dock detaches in place under the pointer instead.
      #
      # Un-docking pins explicit `left`/`top`/`width`/`height` (clearing
      # `right`/`bottom`) so leftover docked constraints don't fight the drag
      # handler's `left`/`top` writes.
      def toggle_floating(restore : Bool = true) : Nil
        return unless floatable?
        if floating?
          save_float_geom # remember where/what size we were, to restore later
          @area = @prev_area || Area::Left
        else
          @prev_area = @area
          if restore && (g = @float_geom)
            apply_rect g
          else
            freeze_rect
          end
          @area = Area::Floating
        end
        refresh_buttons
        emit ::Crysterm::Event::Float, floating?
        window?.try &.schedule_render
      end

      @prev_area : Area?

      # The floating rectangle (`{left, top, width, height}`, parent-relative)
      # captured the last time the dock was floating, restored on the next float.
      @float_geom : Tuple(Int32, Int32, Int32, Int32)?

      # The dock's current rectangle relative to its parent's origin, as
      # `{left, top, width, height}`. Coordinate accessors raise before layout,
      # handled by callers' `rescue`.
      private def current_float_rect : Tuple(Int32, Int32, Int32, Int32)
        # `left`/`top` are relative to the parent's *content* origin
        # (`widget_position.cr` adds `parent.ileft`/`itop`), so the origin to
        # subtract is `parent.aleft + parent.ileft` (and `atop + itop`), not the
        # outer `aleft`/`atop`. Matches `Splitter#wire_divider`.
        px = parent.try { |p| p.aleft + p.ileft } || 0
        py = parent.try { |p| p.atop + p.itop } || 0
        {aleft - px, atop - py, awidth, aheight}
      end

      # Records the current floating rectangle for later restoration.
      private def save_float_geom : Nil
        @float_geom = current_float_rect
      rescue
        # Not laid out yet; nothing to remember.
      end

      # Pins the dock's current absolute rectangle as its floating geometry.
      # No-op before layout (coordinates raise).
      private def freeze_rect : Nil
        apply_rect current_float_rect
      rescue
        # Not laid out yet; keep whatever explicit geometry was given.
      end

      # Applies an explicit floating rectangle, clearing the docked `right`/
      # `bottom` constraints so `left`/`top`/`width`/`height` solely position it.
      private def apply_rect(g : Tuple(Int32, Int32, Int32, Int32)) : Nil
        self.right = nil
        self.bottom = nil
        self.width = g[2]
        self.height = g[3]
        self.left = g[0]
        self.top = g[1]
      end

      # Styles one title-bar button so it always reads as part of the bar. Uses
      # an explicit `::close-button`/`::float-button` rule if matched, else the
      # bar's own style, then fills any unset/terminal-default (`-1`) bg/fg from
      # the bar so a button never paints the terminal bg or hides its glyph.
      private def sync_titlebutton(btn : Box?, sub : Style) : Nil
        return unless btn
        bar = titlebar.style
        st = sub.same?(style) ? bar.dup : sub.dup
        bg = st.bg
        st.bg = bar.bg if bg.nil? || bg == -1
        fg = st.fg
        st.fg = bar.fg if fg.nil? || fg == -1
        btn.styles.normal = st
      end

      private def build_buttons
        @close_button = titlebutton(0, "✕") { close_dock } if closable?
        @float_button = titlebutton(closable? ? 2 : 0, "⇕") { toggle_floating } if floatable?
      end

      # Builds one title-bar button: a 1x1 `Box` pinned to the bar's right edge
      # at *offset*, showing *glyph*, invoking *handler* when clicked.
      private def titlebutton(offset : Int32, glyph : String, &handler : ->) : Box
        btn = Box.new(
          parent: titlebar, top: 0, right: offset, width: 1, height: 1,
          content: glyph, focus_on_click: false,
        )
        btn.add_css_class "titlebutton" # themed via `.titlebutton { ... }`
        btn.on(::Crysterm::Event::Click) { handler.call }
        btn
      end

      private def refresh_buttons
        @float_button.try &.set_content(floating? ? "▣" : "⇕")
        refresh_grip
      end

      # A floatable dock owns a corner resize grip; non-floatable docks get none.
      # Starts hidden, revealed only while floating (`#refresh_grip`).
      private def build_size_grip
        return unless floatable?
        g = SizeGrip.new(
          parent: self, target: self,
          bottom: 0, right: 0, width: 1, height: 1,
          min_drag_width: 12, min_drag_height: 4,
        )
        g.hide
        @size_grip = g
      end

      # A docked pane is resized via its dock separator, not a corner handle, so
      # the grip is shown only while floating and kept in front of the content
      # (which would otherwise paint over it). Placement handled by `#position_grip`.
      private def refresh_grip
        @size_grip.try do |g|
          if floating?
            g.show
            g.front!
          else
            g.hide
          end
        end
      end

      # Plants the grip on the dock's outer bottom-right corner (over the border
      # corner if any) rather than one cell inside it. Child coords are
      # content-relative, so pushed out by the negative border+padding inset;
      # re-derived each frame since a theme can change the border.
      private def position_grip
        @size_grip.try do |g|
          next unless g.visible?
          r = -iright
          b = -ibottom
          g.right = r unless g.right == r
          g.bottom = b unless g.bottom == b
        end
      end

      # Dragging the title bar moves a floating dock; grabbing a docked dock's
      # title bar undocks it in place first (drag-to-float), so the same gesture
      # both detaches and moves it.
      private def wire_drag
        titlebar.enable_drag reposition: false
        titlebar.on(::Crysterm::Event::DragStart) do |e|
          @drag_dx = e.x - aleft
          @drag_dy = e.y - atop
          # Undock in place (`restore: false`) so `aleft`/`atop` — hence the
          # offsets just captured — stay valid and the drag continues smoothly.
          toggle_floating(restore: false) unless floating?
        end
        titlebar.on(::Crysterm::Event::Drag) do |e|
          next unless floating?
          # `left`/`top` are content-origin-relative but the pointer (`e.x`/`e.y`)
          # is absolute; convert by subtracting the parent's content origin
          # (`aleft + ileft`, matching `#current_float_rect`), else the dock only
          # tracks the pointer when its parent has no border/padding.
          px = parent.try { |p| p.aleft + p.ileft } || 0
          py = parent.try { |p| p.atop + p.itop } || 0
          # Clamp against the parent's *content* extent (`awidth - iwidth`), not
          # its outer size, so a floating dock can't be dragged out over the
          # parent's border/padding.
          bound_w = (parent.try { |p| p.awidth - p.iwidth } || (window.awidth - window.iwidth)) - awidth
          bound_h = (parent.try { |p| p.aheight - p.iheight } || (window.aheight - window.iheight)) - aheight
          self.left = (e.x - @drag_dx - px).clamp(0, Math.max(0, bound_w))
          self.top = (e.y - @drag_dy - py).clamp(0, Math.max(0, bound_h))
          request_render
        end
      end
    end
  end
end
