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
      include Mixin::SubStyle
      # A floating dock is an overlay (structural border at the unstyled floor);
      # `#floor_border_value` narrows which sides a docked pane draws.
      include Mixin::Overlay

      # Where the dock sits in a `MainWindow` (or `Floating`, positioned freely).
      enum Area
        Left
        Right
        Top
        Bottom
        Floating
      end

      getter title : String

      # Where the dock sits in a `MainWindow`, which re-lays-out on the next frame.
      getter area : Area

      # :ditto:
      #
      # Not a bare `property`: `#floor_border_value` depends on the area (which
      # side faces the content), so the frame style memoizing it must be dropped
      # with it; the float button's glyph tracks `#floating?` too.
      # Unlike `#toggle_floating` this is not gated on `floatable?` —
      # `floatable` gates the button/gesture, not programmatic moves — but a
      # float transition performs the same bookkeeping: geometry pinning (so
      # leftover docked anchors don't fight the drag handler), `@prev_area`
      # for the float button's re-dock, and `Event::Float`.
      def area=(value : Area) : Area
        return value if @area == value
        was_floating = @area.floating?
        if value.floating? && !was_floating
          @prev_area = @area
          if g = @float_geom
            apply_rect g
          else
            freeze_rect
          end
        elsif was_floating && !value.floating?
          save_float_geom # remember where/what size we were, to restore later
        end
        @area = value
        refresh_buttons
        invalidate_frame_style
        emit ::Crysterm::Event::Float, floating? if value.floating? != was_floating
        window?.try &.update
        value
      end

      # Updates the stored title and the rendered title-bar text.
      def title=(value : String) : String
        return value if value == @title
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

      # Per-button style memo: the `Style` copy last pushed onto the button plus
      # the inputs it was derived from. Steady state reuses the copy instead of
      # duplicating a `Style` per button per frame.
      private class TitlebuttonStyle
        property src : ::Crysterm::Style?
        property src_bg : Int32?
        property src_fg : Int32?
        property bar_bg : Int32?
        property bar_fg : Int32?
        property result : ::Crysterm::Style?
      end

      @close_button_style = TitlebuttonStyle.new
      @float_button_style = TitlebuttonStyle.new

      # The bottom-right resize grip. Present only on a `#floatable?` dock and
      # shown only while floating.
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
        # the cascade; a missing rule is a no-op and the elements keep their
        # `.titlebar`/`.titlebutton` theme look.
        on(::Crysterm::Event::PreRender) do
          apply_substyle titlebar, style.title
          # Float/close buttons default to the bar's own colors so they stay
          # legible under any theme instead of rendering as transparent "black
          # holes". An explicit `::close-button`/`::float-button` rule still
          # supplies the base look; only unset colors fall back to the bar.
          sync_titlebutton @close_button, style.close_button, @close_button_style
          sync_titlebutton @float_button, style.float_button, @float_button_style
          position_grip
        end
      end

      def floating? : Bool
        @area.floating?
      end

      # Floats or re-docks the dock (Qt's `QDockWidget#setFloating`), delegating
      # to `#toggle_floating`. A no-op when already in the requested state or
      # when `#floatable?` is false.
      def floating=(value : Bool) : Bool
        toggle_floating if value != floating?
        value
      end

      # A floating dock is an overlay, so it gets a full frame. A docked pane
      # only needs a border on the side facing the content. Re-synced as the
      # dock floats/re-docks and across `Area` changes.
      def floor_border_value : Bool | Border
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
      # the area below the title bar (Qt's `QDockWidget#setWidget`). `nil`
      # detaches the current content child, leaving the dock empty.
      def widget=(w : Widget?) : Widget?
        if w
          @dock_content = replace_content_child @dock_content, w, top: 1
          # Content is appended after the grip, so it would render over the
          # grip's corner cell without this.
          @size_grip.try(&.to_front)
        else
          @dock_content.try &.remove_from_parent
          @dock_content = nil
          request_render
        end
        w
      end

      # Closes the dock: hides it and emits `Event::Close`.
      def close : Nil
        hide
        emit ::Crysterm::Event::Close
        window?.try &.update
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
      def toggle_floating(*, restore : Bool = true) : Nil
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
        # `floor_border_value` depends on `@area`, so drop the frame-memoized
        # style and let it re-sync on the next `#style` read.
        invalidate_frame_style
        emit ::Crysterm::Event::Float, floating?
        window?.try &.update
      end

      @prev_area : Area?

      # The floating rectangle (`{left, top, width, height}`, parent-relative)
      # captured the last time the dock was floating, restored on the next float.
      @float_geom : Tuple(Int32, Int32, Int32, Int32)?

      # The dock's current rectangle relative to its parent's origin, as
      # `{left, top, width, height}`. Coordinate accessors raise before layout,
      # handled by callers' `rescue`.
      private def current_float_rect : Tuple(Int32, Int32, Int32, Int32)
        # `left`/`top` are relative to the parent's *content* origin, so the
        # origin to subtract is `parent.aleft + parent.ileft` (and `atop + itop`),
        # not the outer `aleft`/`atop`. `drag_origin` is that exact origin, with
        # the window's content corner as the top-level fallback.
        px, py = drag_origin
        # `with_margin: false`: the rect is stored back into `left`/`top`
        # (which layout re-adds the CSS margin to), so a margin-inclusive
        # `aleft`/`atop` would compound the margin on every float toggle.
        {aleft(with_margin: false) - px, atop(with_margin: false) - py, awidth, aheight}
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
      private def sync_titlebutton(btn : Box?, sub : Style, memo : TitlebuttonStyle) : Nil
        return unless btn
        bar = titlebar.style
        # `sub.same?(style)` means no explicit rule matched, so fall back to the
        # bar's own style as the source.
        src = sub.same?(style) ? bar : sub

        # Steady state: reuse the pushed copy — no dup. The cascade replaces
        # sub-`Style` objects on recompute (never mutates them), so identity +
        # bg/fg fully capture whether the output would differ.
        if (cached = memo.result) &&
           (last = memo.src) && last.same?(src) &&
           memo.src_bg == src.bg && memo.src_fg == src.fg &&
           memo.bar_bg == bar.bg && memo.bar_fg == bar.fg
          btn.styles.normal = cached
          return
        end

        st = src.dup
        bg = st.bg
        st.bg = bar.bg if bg.nil? || bg == -1
        fg = st.fg
        st.fg = bar.fg if fg.nil? || fg == -1
        btn.styles.normal = st

        memo.src = src
        memo.src_bg = src.bg
        memo.src_fg = src.fg
        memo.bar_bg = bar.bg
        memo.bar_fg = bar.fg
        memo.result = st
      end

      # Title-bar button glyphs: CSS `DockWidget::close-button { glyph: … }` /
      # `::float-button`, then the registry at the effective tier. Returned as a
      # whole grapheme so a wide or multi-codepoint override renders whole and
      # the button reserves its width.
      private def close_glyph : String
        glyph_str(Glyphs::Role::CloseButton, style.raw_sub_style("close-button"))
      end

      # :ditto:
      private def float_glyph : String
        glyph_str(floating? ? Glyphs::Role::FloatingMark : Glyphs::Role::FloatButton,
          style.raw_sub_style("float-button"))
      end

      private def build_buttons
        @close_button = titlebutton(0, close_glyph) { close } if closable?
        # The float button sits one cell left of the close button (when present),
        # so its offset reserves the close glyph's measured width plus the gap.
        float_offset = closable? ? Unicode.width(close_glyph) + 1 : 0
        @float_button = titlebutton(float_offset, float_glyph) { toggle_floating } if floatable?
      end

      # Builds one title-bar button: a `Box` pinned to the bar's right edge at
      # *offset*, as wide as *glyph* measures (1 for the classic single-cell
      # marks, 2 for an emoji-presentation override), showing *glyph*, invoking
      # *handler* when clicked.
      private def titlebutton(offset : Int32, glyph : String, &handler : ->) : Box
        btn = Box.new(
          parent: titlebar, top: 0, right: offset, width: Unicode.width(glyph), height: 1,
          content: glyph, focus_on_click: false,
        )
        btn.add_css_class "titlebutton" # themed via `.titlebutton { ... }`
        btn.on(::Crysterm::Event::Click) { handler.call }
        btn
      end

      private def refresh_buttons
        # Re-measure: the float mark swaps FloatButton⇄FloatingMark on
        # dock/float and either state may carry a wide override, so the button's
        # reserved width tracks the current glyph.
        @close_button.try { |b| set_button b, close_glyph }
        @float_button.try { |b| set_button b, float_glyph }
        refresh_grip
      end

      # Points a title-bar button at *glyph*, reserving its measured width.
      private def set_button(btn : Box, glyph : String) : Nil
        w = Unicode.width(glyph)
        btn.width = w unless btn.width == w
        btn.set_content(glyph)
      end

      # A floatable dock owns a corner resize grip; non-floatable docks get none.
      # Starts hidden, revealed only while floating.
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
      # the grip is shown only while floating and kept in front of the content,
      # which would otherwise paint over it.
      private def refresh_grip
        @size_grip.try do |g|
          if floating?
            g.show
            g.to_front
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
        titlebar.drag_mode = :transfer
        titlebar.draggable = true
        titlebar.on(::Crysterm::Event::DragStart) do |e|
          # `with_margin: false`: the offsets are replayed into `left`/`top` on
          # Drag, which layout re-adds the CSS margin to — a margin-inclusive
          # origin would make the dock jump by the margin on the first motion.
          @drag_dx = e.x - aleft(with_margin: false)
          @drag_dy = e.y - atop(with_margin: false)
          # Undock in place (`restore: false`) so `aleft`/`atop` — hence the
          # offsets just captured — stay valid and the drag continues smoothly.
          toggle_floating(restore: false) unless floating?
        end
        titlebar.on(::Crysterm::Event::Drag) do |e|
          next unless floating?
          # `left`/`top` are content-origin-relative but the pointer is absolute,
          # so subtract the parent's content origin — else the dock only tracks
          # the pointer when its parent has no border/padding. The clamps are
          # against the parent's *content* extent, so a floating dock can't be
          # dragged out over the parent's border/padding.
          ox, oy = drag_origin
          self.left = (e.x - @drag_dx - ox).clamp(0, drag_max_left)
          self.top = (e.y - @drag_dy - oy).clamp(0, drag_max_top)
          request_render
        end
      end
    end
  end
end
