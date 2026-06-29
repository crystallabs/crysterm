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
    # ![DockWidget screenshot](../../examples/widget/dock_widget/dock_widget-capture5s.apng)
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

      # The bottom-right resize grip (Qt's `QSizeGrip`). Present only on a
      # `#floatable?` dock and shown only while floating — a docked pane is
      # resized via its dock separator, not a corner handle (see `#refresh_grip`).
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
        # title bar and its buttons. Push each computed sub-style onto the matching
        # child box each frame after the cascade; guarded by `same?`, so without a
        # matching rule it's a no-op and the elements keep their `.titlebar`/
        # `.titlebutton` theme look. (An explicit rule replaces that look, as in
        # Qt.) See `Widget::TabWidget#sync_tab_style`.
        on(::Crysterm::Event::PreRender) do
          apply_substyle titlebar, style.title
          # The float/close buttons are glyphs sitting *on* the title bar, so they
          # take the bar's own colors by default — keeping them legible under any
          # theme instead of rendering as transparent "black holes". (Qt's
          # `::close-button { background: transparent }` lowers to the terminal
          # default, which paints the window background, not the bar's.) An
          # explicit `::close-button`/`::float-button` rule still supplies the base
          # look; only a color it leaves unset falls back to the bar.
          sync_titlebutton @close_button, style.close_button
          sync_titlebutton @float_button, style.float_button
          position_grip
        end
      end

      def floating? : Bool
        @area.floating?
      end

      # A dock always carries a structural border at the unstyled floor (see
      # `#floor_border_value` for *which* sides); under a theme the cascade owns
      # the border instead.
      def floor_border? : Bool
        true
      end

      # A *floating* dock is an overlay over the central content, so it gets a
      # full frame to read against what it covers. A *docked* pane abuts one edge
      # of the window, so it only needs a border on the single side facing the
      # content — enough to part it from the central area without boxing in the
      # whole panel. `#ensure_floor_border` re-syncs this as the dock floats and
      # re-docks (and across `Area` changes).
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
        @dock_content.try &.remove_from_parent
        @dock_content = w
        w.top = 1
        w.left = 0
        w.right = 0
        w.bottom = 0
        append w
        # Content is appended after the grip (built in `#initialize`), so it
        # would render over the grip's corner cell. Keep the grip on top.
        @size_grip.try(&.front!)
        request_render
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
      # Docking remembers the floating rectangle; *restore*-ing (the default, used
      # by the ⇕ button) puts the dock back at exactly that position and size on
      # the next float, rather than leaving it at the docked size. The drag-undock
      # path passes `restore: false` so the dock detaches *in place* under the
      # pointer instead of jumping back to its old floating spot.
      #
      # Either way, un-docking pins an explicit `left`/`top`/`width`/`height`
      # (clearing `right`/`bottom`) so the now-floating dock has one unambiguous
      # geometry — otherwise the leftover docked constraints (`right` + `width`,
      # `top` + `bottom`) and the drag handler's `left`/`top` writes would fight.
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

      # The dock's current rectangle expressed relative to its parent's origin,
      # as `{left, top, width, height}`. The coordinate accessors raise before the
      # dock has been laid out, which the callers' own `rescue` handles.
      private def current_float_rect : Tuple(Int32, Int32, Int32, Int32)
        px = parent.try(&.aleft) || 0
        py = parent.try(&.atop) || 0
        {aleft - px, atop - py, awidth, aheight}
      end

      # Records the current floating rectangle for later restoration.
      private def save_float_geom : Nil
        @float_geom = current_float_rect
      rescue
        # Not laid out yet; nothing to remember.
      end

      # Pins the dock's current absolute rectangle as its explicit floating
      # geometry. No-op before the dock has been laid out (its coordinates raise).
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

      # Styles one title-bar button so it always reads as part of the bar. Starts
      # from an explicit `::close-button`/`::float-button` rule when one matched,
      # else the bar's own style, then fills any unset/terminal-default (`-1`)
      # background or foreground from the bar — so a button can never paint the
      # terminal background (a "black hole") or hide its glyph against its own bg.
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

      # Builds one title-bar button: a 1×1 `Box` pinned to the bar's right edge at
      # *offset*, showing *glyph*, themed via `.titlebutton`, and invoking
      # *handler* when clicked. Shared by the close and float buttons.
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

      # A floatable dock owns a corner resize grip (Qt's `QSizeGrip`); a
      # non-floatable dock can't detach, so it gets none. Targets the dock itself
      # and starts hidden — it is revealed only while floating (`#refresh_grip`).
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

      # The resize grip is a floating-window affordance: a docked pane is resized
      # via its dock separator, not a corner handle, so a grip shown while docked
      # would be an inert, misleading control. Show it only when floating, and
      # keep it in front of the dock's content (which fills the corner the grip
      # sits in — otherwise the content paints over it). Placement is handled per
      # frame by `#position_grip`.
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

      # Plant the (floating-only) grip on the dock's outer bottom-right corner —
      # *over* the border corner when there is one — rather than one cell inside
      # it. Child coordinates are content-relative (inside the frame), so the grip
      # is pushed back out by the negative border+padding inset; re-derived each
      # frame since a theme can change the border. With no border/padding the
      # inset is 0 and the grip simply sits at the corner cell.
      private def position_grip
        @size_grip.try do |g|
          next unless g.visible?
          r = -iright
          b = -ibottom
          g.right = r unless g.right == r
          g.bottom = b unless g.bottom == b
        end
      end

      # Dragging the title bar moves a floating dock; grabbing the title bar of a
      # *docked* dock undocks it in place first (Qt's drag-to-float), so the same
      # gesture both detaches and moves it — giving every dock a drag handle.
      private def wire_drag
        titlebar.enable_drag reposition: false
        titlebar.on(::Crysterm::Event::DragStart) do |e|
          @drag_dx = e.x - aleft
          @drag_dy = e.y - atop
          # Undock on grab, *in place* (`restore: false`): the dock detaches at
          # its current spot so `aleft`/`atop` — hence the offsets just captured —
          # stay valid and the drag continues smoothly from the grab point.
          toggle_floating(restore: false) unless floating?
        end
        titlebar.on(::Crysterm::Event::Drag) do |e|
          next unless floating?
          # `left`/`top` are parent-relative but the pointer (`e.x`/`e.y`) is
          # absolute, so convert by subtracting the parent's origin — matching the
          # `aleft - px` convention in `#save_float_geom`/`#freeze_rect`. Without
          # this the dock only tracked the pointer when its parent sat at the
          # window origin (the same class of bug `Splitter#wire_divider` notes).
          px = parent.try(&.aleft) || 0
          py = parent.try(&.atop) || 0
          bound_w = (parent.try(&.awidth) || window.awidth) - awidth
          bound_h = (parent.try(&.aheight) || window.aheight) - aheight
          self.left = (e.x - @drag_dx - px).clamp(0, Math.max(0, bound_w))
          self.top = (e.y - @drag_dy - py).clamp(0, Math.max(0, bound_h))
          request_render
        end
      end
    end
  end
end
