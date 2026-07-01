module Crysterm
  class Widget
    # module Interaction

    property? interactive = false

    # Is element clickable?
    property? clickable = false

    # Whether this widget should receive mouse events by default.
    #
    # A widget is mouse-responsive if it is interactive (`input?`/`keyable?`),
    # `scrollable?`, `draggable?`, explicitly marked `clickable?`, or already has
    # a `Click`/`Mouse` listener attached. Used by `Window#widget_at` for
    # hit-testing, so a plain `Box` that later gets an `Event::Click` handler
    # automatically starts receiving clicks without also setting `clickable: true`.
    def wants_mouse?
      clickable? || input? || keyable? || scrollable? || draggable? ||
        # A widget listening for drops is a drop target and must be hit-testable
        # so an in-flight drag can target it.
        handlers(Crysterm::Event::DragEnter).any? ||
        handlers(Crysterm::Event::DragOver).any? ||
        handlers(Crysterm::Event::DragLeave).any? ||
        handlers(Crysterm::Event::Drop).any? ||
        handlers(Crysterm::Event::Click).any? ||
        handlers(Crysterm::Event::Mouse).any? ||
        # Hover events subclass `Mouse` but are emitted/registered separately;
        # check explicitly or a widget with only hover handlers is never hit-tested.
        handlers(Crysterm::Event::MouseOver).any? ||
        handlers(Crysterm::Event::MouseMove).any? ||
        handlers(Crysterm::Event::MouseOut).any?
    end

    # Can element receive keyboard input? (Managed internally; use `input` for user-side setting)
    property? keyable = false

    # Is element draggable?
    property? draggable = false

    property? focus_on_click = true

    property? vi : Bool = false

    # Does it accept keyboard input?
    property? input = false

    # Is the widget disabled? While disabled it does not react to keyboard
    # input (see `Window#_listen_keys`). Toggle via `state = WidgetState::Disabled`.
    def disabled?
      state.disabled?
    end

    # Should widget react to some pre-defined keys in it?
    property? keys : Bool = false

    property? ignore_keys : Bool = false

    # property? clickable = false

    # Puts current widget in focus
    def focus
      # XXX Prevents multiple `Event::Focus`es. TBD whether repeated `#focus`
      # calls should always re-fire instead.
      return if focused?
      window.focus self
    end

    # Returns whether widget is currently in focus.
    #
    # Uses the non-raising `#window?`: a detached widget holds no `@window` and
    # derives none through a parent, so the raising `#window` would crash this
    # pure query with `NilAssertionError`. A detached widget is never the
    # window's focused widget, so the answer there is `false`.
    @[AlwaysInline]
    def focused?
      window?.try(&.focused) == self
    end

    # Hover help text shown in a floating `Widget::ToolTip` while the pointer is
    # over this widget (Qt's `QWidget#toolTip`). `nil` means none.
    getter tool_tip : String?

    # The shared per-widget tooltip overlay, created lazily on first hover.
    @_tooltip : Widget::ToolTip?
    # Whether the hover handlers have been installed (so re-setting the text
    # doesn't stack duplicate handlers).
    @_tooltip_wired = false

    # Sets the hover help text. Setting a non-nil value makes the widget
    # mouse-hover-tracked (it begins receiving `Event::MouseOver`/`MouseOut`) and
    # shows/hides the tooltip automatically. Set `nil` to disable.
    def tool_tip=(text : String?)
      @tool_tip = text
      wire_tooltip if text && !@_tooltip_wired
      text
    end

    # Qt's `QWidget#setToolTip`. Kept (and de-stubbed) under the original Blessed
    # name; both route to `#tool_tip=`.
    def set_hover(hover_text : String?)
      self.tool_tip = hover_text
    end

    # Whether the absolute point (*x*, *y*) lies within this widget's last-laid-out
    # rectangle. Returns false before layout (coordinates raise). Shared hit-test
    # used by pop-ups for outside-click dismissal and grab containment.
    def contains_point?(x : Int32, y : Int32) : Bool
      l = aleft
      t = atop
      l <= x < l + awidth && t <= y < t + aheight
    rescue
      false
    end

    # Whether the absolute point (*x*, *y*) belongs to this widget's *grab
    # region* — used by `Window`'s input-grab to decide which points still
    # interact while this widget is grabbing (see `Window#grab`). Default is the
    # widget's own rectangle; pop-ups owning extra area (drop-downs, submenus)
    # override this.
    def grab_contains?(x : Int32, y : Int32) : Bool
      contains_point? x, y
    end

    # Hides the tooltip (if shown). Qt's `QToolTip::hideText`.
    def remove_hover
      @_tooltip.try &.hide
      window?.try &.schedule_render
    end

    private def wire_tooltip : Nil
      @_tooltip_wired = true
      on(Crysterm::Event::MouseOver) { |e| show_tooltip e.x, e.y }
      on(Crysterm::Event::MouseOut) { remove_hover }
      # A hidden widget must not leave its tooltip lingering.
      on(Crysterm::Event::Hide) { remove_hover }
    end

    # The GUI mouse-pointer shape requested while the pointer is over this widget
    # — e.g. `::Tput::MouseCursorShape::PointingHandCursor` for a clickable
    # widget. `nil` leaves the pointer unchanged.
    #
    # Honored only when `Window#mouse_cursor_shape?` (the `mouse.cursor_shape`
    # config option, off by default) is on, and only on terminals supporting
    # OSC 22 (xterm-class); otherwise silently ignored. See
    # `::Tput::Output#mouse_cursor_shape`.
    getter mouse_cursor_shape : ::Tput::MouseCursorShape?

    # Whether the pointer-shape hover handlers have been installed (so re-setting
    # the shape doesn't stack duplicate handlers).
    @_mouse_cursor_shape_wired = false

    # Sets the hover mouse-pointer shape. A non-nil value makes the widget
    # mouse-hover-tracked: the GUI pointer takes *shape* on enter and reverts to
    # the terminal default on leave. `nil` stops requesting a shape
    # (already-installed handlers become no-ops; next leave restores default).
    def mouse_cursor_shape=(shape : ::Tput::MouseCursorShape?)
      @mouse_cursor_shape = shape
      wire_mouse_cursor_shape if shape && !@_mouse_cursor_shape_wired
      shape
    end

    private def wire_mouse_cursor_shape : Nil
      @_mouse_cursor_shape_wired = true
      on(Crysterm::Event::MouseOver) do
        @mouse_cursor_shape.try { |shape| window?.try &.set_mouse_cursor_shape shape }
      end
      on(Crysterm::Event::MouseOut) { window?.try &.set_mouse_cursor_shape nil }
      # If hidden while it owns the pointer shape, restore the default: no
      # `MouseOut` fires for a widget that vanishes under the pointer.
      on(Crysterm::Event::Hide) do
        s = window?
        s.set_mouse_cursor_shape nil if s && s.hovered == self
      end
    end

    private def show_tooltip(x : Int32, y : Int32) : Nil
      text = @tool_tip
      return unless text && !text.empty?
      return unless s = window?
      tip = (@_tooltip ||= begin
        t = Widget::ToolTip.new window: s
        s.append t
        t
      end)
      # Offset by one cell so the label doesn't sit under the cursor itself.
      tip.show_at x + 1, y + 1, text
    end

    # Read/write `@draggable` (declared by `property? draggable`, set by the
    # constructor). Previously used a separate `@_draggable` ivar the
    # constructor never touched, so `Widget.new(draggable: true)` left
    # `draggable?` reporting false.
    def draggable?
      @draggable
    end

    def draggable=(draggable : Bool)
      draggable ? enable_drag : disable_drag
    end

    # Grab offset captured at `DragStart`, so a reposition keeps the grabbed
    # point under the pointer rather than snapping the corner to it.
    @_drag_dx = 0
    @_drag_dy = 0

    # Whether the default reposition handlers have been installed (so toggling
    # `draggable` repeatedly doesn't stack duplicate handlers).
    @_drag_reposition_installed = false

    # Marks the widget as a drag source. By default also installs **reposition**
    # behavior: while dragged (mouse or keyboard) the widget follows the anchor
    # by editing its own `left`/`top` ("self-move", matching Blessed's `enableDrag`).
    #
    # Pass `reposition: false` for a **data-transfer** source that stays put and
    # hands a payload to a drop target instead — fill `data` in your own
    # `Event::DragStart` handler and react in `Event::DragEnd`/`Event::Drop`.
    def enable_drag(reposition = true) : Bool
      @draggable = true

      if reposition && !@_drag_reposition_installed
        @_drag_reposition_installed = true

        on(Crysterm::Event::DragStart) do |e|
          @_drag_dx = e.x - aleft
          @_drag_dy = e.y - atop
        end

        on(Crysterm::Event::Drag) do |e|
          # `e.x`/`e.y` are absolute cell coordinates, but `left`/`top` are
          # relative to the parent's content origin (`aleft = parent.aleft +
          # parent.ileft + left`). Subtract that origin so a nested draggable
          # widget tracks the pointer instead of jumping by its parent's absolute
          # position. For a top-level widget with no insets, origin is (0, 0).
          ox, oy = drag_origin
          self.left = (e.x - @_drag_dx - ox).clamp(0, drag_max_left)
          self.top = (e.y - @_drag_dy - oy).clamp(0, drag_max_top)
        end
      end

      @draggable
    end

    # Absolute origin of this widget's `left`/`top` coordinate space — where
    # `left`/`top` of 0 maps to in absolute cells. For a nested widget that's the
    # parent's content corner (`parent.aleft + parent.ileft`); for a top-level
    # widget it's the window's content corner — `(window.ileft, window.itop)`,
    # since `aleft == window.ileft + left` (see `window.cr`). Used by the drag
    # handler to convert the pointer's absolute position into a parent-relative
    # `left`/`top`.
    private def drag_origin : Tuple(Int32, Int32)
      if p = parent
        {p.aleft + p.ileft, p.atop + p.itop}
      else
        s = window
        {s.ileft, s.itop}
      end
    end

    # Largest `left`/`top` that keeps the widget within its parent (or window,
    # if parented directly to it).
    #
    # `left`/`top` are measured from the parent's content origin (`drag_origin`
    # = `parent.aleft + parent.ileft`), so the clamp must use the parent's inner
    # content extent — `awidth - iwidth` (`iwidth` = summed left+right inset, see
    # `widget_decoration`) — not the full `awidth`, or a nested widget could be
    # dragged past the parent's border by the inset amount. Same logic applies
    # when the parent is the window (mirrors `drag_origin`).
    private def drag_max_left : Int32
      c = parent_or_window
      {c.awidth - c.iwidth - awidth, 0}.max
    end

    private def drag_max_top : Int32
      c = parent_or_window
      {c.aheight - c.iheight - aheight, 0}.max
    end

    # Whether this widget self-moves while dragged (reposition behavior
    # installed). A transfer-only source (`enable_drag reposition: false`)
    # returns false, which the engine uses to decide whether to float a drag
    # "ghost".
    def drag_repositions? : Bool
      @_drag_reposition_installed
    end

    def disable_drag : Bool
      @draggable = false
    end

    # :nodoc:
    # no-op in this place
    def _update_cursor(arg)
    end
  end
end
