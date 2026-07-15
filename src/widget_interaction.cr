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
        has_handlers?(Crysterm::Event::DragEnter) ||
        has_handlers?(Crysterm::Event::DragOver) ||
        has_handlers?(Crysterm::Event::DragLeave) ||
        has_handlers?(Crysterm::Event::Drop) ||
        has_handlers?(Crysterm::Event::Click) ||
        has_handlers?(Crysterm::Event::Mouse) ||
        # Hover events subclass `Mouse` but are emitted/registered separately;
        # check explicitly or a widget with only hover handlers is never hit-tested.
        has_handlers?(Crysterm::Event::MouseOver) ||
        has_handlers?(Crysterm::Event::MouseMove) ||
        has_handlers?(Crysterm::Event::MouseOut)
    end

    # Can element receive keyboard input? (Managed internally; use `input` for user-side setting)
    property? keyable = false

    # Is element draggable?
    property? draggable = false

    property? focus_on_click = true

    property? vi : Bool = false

    # Does it accept keyboard input?
    property? input = false

    # Whether the widget reacts to keyboard input (Qt's `QWidget#isEnabled`).
    # Derived from `#state`, which is single-valued: a widget is disabled exactly
    # while it is in `WidgetState::Disabled`.
    def enabled? : Bool
      !state.disabled?
    end

    # Is the widget disabled? While disabled it does not react to keyboard
    # input (see `Window#_listen_keys`) and Tab/Shift+Tab step over it (see
    # `Window#focus_offset`).
    def disabled? : Bool
      state.disabled?
    end

    # Enables/disables the widget (Qt's `QWidget#setEnabled`), emitting
    # `Event::EnabledChanged` on a real change.
    #
    # Backed by `#state` rather than a flag of its own, so `Disabled` can't drift
    # out of sync with the state the renderer and `Window#_listen_keys` read.
    # Since `WidgetState` is single-valued, enabling resolves to `Normal` —
    # re-disabling a widget that was `Focused`/`Hovered`/`Selected` and then
    # re-enabling it lands on `Normal`, not the prior state. `#state=` already
    # handles `mark_dirty` and the CSS re-cascade (`state-disabled` rules).
    def enabled=(value : Bool) : Bool
      return value if value == enabled?
      self.state = value ? WidgetState::Normal : WidgetState::Disabled
      emit ::Crysterm::Event::EnabledChanged, value
      value
    end

    # :ditto: — inverted (Qt has no `setDisabled` counterpart on the getter side,
    # but the setter exists).
    def disabled=(value : Bool) : Bool
      self.enabled = !value
      value
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

    # Drops keyboard focus from this widget (Qt's `QWidget#clearFocus`), handing
    # it to the most recent still-valid entry in the window's focus history — or
    # blurring outright when none remains. No-op unless this widget currently
    # holds focus, so it can't disturb an unrelated focused widget.
    #
    # `Window#rewind_focus` (not `focus_pop`) is what pops-and-revalidates: it
    # prunes history entries that have since been detached or hidden, which is
    # exactly the state a widget being un-focused tends to be left in.
    def clear_focus : Nil
      return unless focused?
      window?.try &.rewind_focus
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

    # Whether the absolute point (*x*, *y*) lies within this widget's last-laid-out
    # rectangle. Returns false before layout (coordinates raise). Shared hit-test
    # used by pop-ups for outside-click dismissal and grab containment.
    def contains_point?(x : Int32, y : Int32) : Bool
      # Prefer the painted rectangle (`lpos`): like `Window#widget_at`, it carries
      # the margin shift, enclosing-scroll offset and clipping, so a scrolled or
      # clipped widget is tested where it actually appears (and one painted to
      # nothing, `lpos == nil`, is never contained). Fall back to the computed
      # rectangle only before the first render, when `lpos` is still nil for a
      # widget that has laid out but not painted; `aleft` may raise pre-layout, so
      # keep the rescue.
      if lp = lpos
        return lp.xi <= x < lp.xl && lp.yi <= y < lp.yl
      end
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

    # Hides the shown tooltip. Qt's `QToolTip::hideText`. Does not clear
    # `#tool_tip`; the text stays and pops up again on the next hover.
    def hide_tool_tip
      @_tooltip.try &.hide
      # Render the tooltip's OWN window, not the widget's: after a cross-window
      # reparent the tooltip may still live on the window it was created on, and
      # `Widget#hide` schedules no render itself — so the old surface would keep
      # showing the tooltip frame if we only re-rendered the widget's window.
      @_tooltip.try &.window?.try &.schedule_render
    end

    private def wire_tooltip : Nil
      @_tooltip_wired = true
      on(Crysterm::Event::MouseOver) { |e| show_tooltip e.x, e.y }
      on(Crysterm::Event::MouseOut) { hide_tool_tip }
      # A hidden widget must not leave its tooltip lingering.
      on(Crysterm::Event::Hide) { hide_tool_tip }
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
      # A cross-window reparent strands the cached tooltip on the old window (it
      # is a *satellite* window child, not ours), so reusing it would pop the
      # tip up on the wrong surface at this window's coordinates. Drop the stale
      # tooltip and let the lazy-create below rebuild it on the current window.
      if (stale = @_tooltip) && stale.window? != s
        ::Crysterm::Widget.destroy_satellite stale
        @_tooltip = nil
      end
      tip = (@_tooltip ||= begin
        t = Widget::ToolTip.new window: s
        s.append t
        t
      end)
      # Offset by one cell so the label doesn't sit under the cursor itself.
      tip.show_at x + 1, y + 1, text
    end

    # Reads `@draggable` (declared by `property? draggable`, set by the
    # constructor) directly, so `Widget.new(draggable: true)` is reflected by
    # `draggable?`. A separate ivar the constructor never touches would leave it
    # reporting false.
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
          # Grab against the margin-LESS origin: `aleft`/`atop` default to
          # `with_margin: true`, but `coords` shifts the drawn box outward by
          # the margin again — capturing the margin-inclusive origin here would
          # double-count `margin.left`/`margin.top`, jumping the widget right/down
          # by its own margin on the first motion. This also keeps the keyboard
          # `drag_nudge` re-sync (window_drag.cr) exact.
          @_drag_dx = e.x - aleft(with_margin: false)
          @_drag_dy = e.y - atop(with_margin: false)
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
    # `left`/`top`. `protected` so subclasses with a custom drag entry
    # (`ColorDialog`, `DockWidget`) reuse this exact origin math.
    protected def drag_origin : Tuple(Int32, Int32)
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
    # content extent — `awidth - ihorizontal` (`ihorizontal` = summed left+right inset, see
    # `widget_decoration`) — not the full `awidth`, or a nested widget could be
    # dragged past the parent's border by the inset amount. Same logic applies
    # when the parent is the window (mirrors `drag_origin`).
    protected def drag_max_left : Int32
      c = parent_or_window
      {c.awidth - c.ihorizontal - awidth, 0}.max
    end

    protected def drag_max_top : Int32
      c = parent_or_window
      {c.aheight - c.ivertical - aheight, 0}.max
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
    # no-op in this place. `Mixin::TextEditing` (and `LineEdit`) override it
    # publicly — placing the caret is part of an editable widget's API.
    protected def _update_cursor(arg)
    end
  end
end
