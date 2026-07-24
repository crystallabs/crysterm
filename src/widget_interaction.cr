module Crysterm
  class Widget
    # module Interaction

    include Mixin::KeyShortcuts

    property? interactive = false

    # Directs all subsequent mouse motion/release to this widget until the
    # button is released (Qt's `QWidget#grabMouse`, called from a press
    # handler) — the terminal counterpart is the window's `#capture_mouse`.
    # No-op while detached.
    def grab_mouse : Nil
      window?.try &.capture_mouse(self)
    end

    # Ends this widget's mouse grab (Qt's `QWidget#releaseMouse`). Only
    # releases a capture this widget itself holds, so it can't cut short
    # another widget's in-flight gesture.
    def release_mouse : Nil
      window?.try { |w| w.release_mouse if w.mouse_captor == self }
    end

    # Focuses this widget and routes keys to it ONLY — no bubbling up the
    # ancestor chain — until `#release_keyboard` (Qt's `QWidget#grabKeyboard`).
    # The window's `#always_propagated_keys` (Tab & co.) still bubble. Reading
    # widgets (`LineEdit`, `TextEdit`) grab automatically for the duration of
    # an active read. No-op while detached.
    def grab_keyboard : Nil
      window?.try do |w|
        focus
        w.grab_keys = true
      end
    end

    # Ends a keyboard grab (Qt's `QWidget#releaseKeyboard`). Only releases
    # while this widget holds focus (the keyboard routes to the focused widget,
    # so a non-focused widget has nothing to release).
    def release_keyboard : Nil
      window?.try { |w| w.grab_keys = false if focused? }
    end

    # Actions installed on this widget via `#add_action` (Qt's
    # `QWidget#actions`). Empty for the vast majority of widgets, so the list
    # is allocated lazily.
    def actions : Array(Action)
      @_actions ||= [] of Action
    end

    @_actions : Array(Action)?

    # Whether the attach/detach handlers that (un)install action shortcuts have
    # been wired (once, on the first `#add_action`).
    @_actions_wired = false

    # Installs *action* on this widget (Qt's `QWidget#addAction`): the action's
    # keyboard shortcut becomes active on the widget's window — gated on this
    # widget holding focus when the action's `shortcut_context` is
    # `Widget`/`WidgetWithChildren` — and follows the widget across
    # attach/detach. Unlike `Menu#add_action`/`ToolBar#add_action` this
    # *presents nothing*; it is the way to give any widget a shortcut-reachable
    # command. Idempotent; returns *action*.
    def add_action(action : Action) : Action
      acts = actions
      return action if acts.includes? action
      acts << action
      action.associate self
      wire_actions
      window?.try { |w| action.install_shortcut w, self }
      action
    end

    # Removes *action* (Qt's `QWidget#removeAction`): withdraws its shortcut
    # from the window and forgets it. No-op when not installed.
    def remove_action(action : Action) : Nil
      return unless @_actions.try &.delete(action)
      action.dissociate self
      window?.try { |w| action.uninstall_shortcut w }
    end

    # Wires the attach/detach lifecycle for installed actions — once, lazily,
    # so widgets that never carry actions don't pay for the handlers.
    private def wire_actions : Nil
      return if @_actions_wired
      @_actions_wired = true
      on(Crysterm::Event::Attached) do
        window?.try { |w| @_actions.try &.each(&.install_shortcut(w, self)) }
      end
      # `@window` is already nulled when `Detached` fires; the window being
      # left rides in the event payload (same contract `ToolBar` relies on).
      on(Crysterm::Event::Detached) do |e|
        e.object.as?(::Crysterm::Window).try do |w|
          @_actions.try &.each(&.uninstall_shortcut(w))
        end
      end
    end

    # Is element clickable?
    property? clickable = false

    # Whether this widget should receive mouse events by default: it is
    # interactive, scrollable, draggable, explicitly `clickable?`, or already has
    # a mouse listener attached. Keying off the listeners means a plain `Box` that
    # gets an `Event::Click` handler starts receiving clicks without also being
    # marked `clickable: true`.
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
        has_handlers?(Crysterm::Event::MouseEnter) ||
        has_handlers?(Crysterm::Event::MouseMove) ||
        has_handlers?(Crysterm::Event::MouseLeave)
    end

    # The ways a widget accepts keyboard focus (Qt's `Qt::FocusPolicy`).
    enum FocusPolicy
      # Does not accept focus.
      None
      # Accepts focus by Tab/Shift+Tab only.
      Tab
      # Accepts focus by clicking only (skipped by Tab navigation).
      Click
      # Accepts focus by both Tab and click (the interactive-widget default).
      Strong
      # `Strong`, plus the mouse wheel focuses it.
      Wheel

      # Whether Tab/Shift+Tab may land on a widget with this policy.
      def accepts_tab? : Bool
        tab? || strong? || wheel?
      end

      # Whether a click focuses a widget with this policy.
      def accepts_click? : Bool
        click? || strong? || wheel?
      end

      # Whether the mouse wheel focuses a widget with this policy.
      def accepts_wheel? : Bool
        wheel?
      end
    end

    # The explicitly-assigned focus policy, or `nil` while the widget still
    # runs on the legacy flags (`keys`/`input` + `focus_on_click`) it was
    # constructed with. Explicit assignment becomes authoritative.
    @focus_policy : FocusPolicy?

    # The ways this widget accepts keyboard focus (Qt's `QWidget#focusPolicy`).
    # Until a policy is set explicitly, it is derived from the legacy flags: a
    # key-enabled widget (`keys`/`input`/`keyable`) maps to `Strong` (or `Tab`
    # when `focus_on_click` is off), anything else to `None`.
    def focus_policy : FocusPolicy
      @focus_policy || begin
        if keyable? || keys? || input?
          focus_on_click? ? FocusPolicy::Strong : FocusPolicy::Tab
        else
          FocusPolicy::None
        end
      end
    end

    # Sets the focus policy (Qt's `QWidget#setFocusPolicy`), accepting a
    # `Symbol` shorthand (`w.focus_policy = :none`). Keeps the legacy flags in
    # sync: `None` de-registers the widget from keyboard input entirely, any
    # accepting policy key-enables it (and `Tab`-only turns click-to-focus
    # off). `Click` is honored by Tab navigation (skipped) and mouse focus;
    # wheel-focus is granted only by `Wheel`, per Qt.
    def focus_policy=(policy : FocusPolicy) : FocusPolicy
      @focus_policy = policy
      if policy.none?
        @keys = false
        @input = false
        @keyable = false
        window?.try &.unregister_keyable(self)
      else
        @keys = true
        @focus_on_click = policy.accepts_click?
        window?.try &.register_keyable(self)
      end
      policy
    end

    # Whether Tab/Shift+Tab navigation may land on this widget. Follows the
    # explicit `#focus_policy` when one was set (`Click` widgets are skipped);
    # otherwise the legacy behavior — every key-registered widget is a Tab
    # target.
    def accepts_tab_focus? : Bool
      @focus_policy.try(&.accepts_tab?) != false
    end

    # Whether a mouse wheel over this widget focuses it. With an explicit
    # `#focus_policy` this is Qt's rule — only `Wheel` grants it; the legacy
    # default (no explicit policy) keeps the historical behavior of wheel
    # focusing any click-focusable widget.
    def accepts_wheel_focus? : Bool
      if policy = @focus_policy
        policy.accepts_wheel?
      else
        focus_on_click? && keyable?
      end
    end

    # Can element receive keyboard input? (Managed internally; use `input` for user-side setting)
    property? keyable = false

    # Is element draggable?
    property? draggable = false

    property? focus_on_click = true

    property? vi_keys : Bool = false

    # Does it accept keyboard input?
    property? input = false

    # Whether the widget reacts to keyboard input (Qt's `QWidget#isEnabled`).
    # Derived from `#state`, which is single-valued: a widget is disabled exactly
    # while it is in `WidgetState::Disabled`.
    def enabled? : Bool
      !state.disabled?
    end

    # Is the widget disabled? While disabled it does not react to keyboard input
    # and Tab/Shift+Tab step over it.
    def disabled? : Bool
      state.disabled?
    end

    # Enables/disables the widget (Qt's `QWidget#setEnabled`), emitting
    # `Event::EnabledChanged` on a real change.
    #
    # Backed by `#state` rather than a flag of its own, so `Disabled` can't drift
    # out of sync with the state the renderer reads. Since `WidgetState` is
    # single-valued, enabling always resolves to `Normal` — never back to a prior
    # `Focused`/`Hovered`/`Selected`.
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

    # Puts current widget in focus. No-op while detached.
    def focus
      # XXX Prevents multiple `Event::FocusIn`es. TBD whether repeated `#focus`
      # calls should always re-fire instead.
      return if focused?
      window?.try &.focus self
    end

    # Drops keyboard focus from this widget (Qt's `QWidget#clearFocus`), handing
    # it to the most recent still-valid entry in the window's focus history — or
    # blurring outright when none remains. No-op unless this widget currently
    # holds focus, so it can't disturb an unrelated focused widget.
    def clear_focus : Nil
      return unless focused?
      window?.try &.rewind_focus
    end

    # Returns whether widget is currently in focus. `false` for a detached
    # widget, which is never the window's focused widget.
    @[AlwaysInline]
    def focused?
      window?.try(&.focused) == self
    end

    # Whether the pointer currently hovers this widget (its window's
    # `#hovered` is this widget). `false` for a detached widget, which is
    # never the window's hovered widget.
    @[AlwaysInline]
    def under_mouse? : Bool
      window?.try(&.hovered) == self
    end

    # Hover help text shown in a floating `Widget::ToolTip` while the pointer is
    # over this widget (Qt's `QWidget#toolTip`). `nil` means none.
    getter tool_tip : String?

    # The shared per-widget tooltip overlay, created lazily on first hover.
    @_tool_tip : Widget::ToolTip?
    # Whether the hover handlers have been installed (so re-setting the text
    # doesn't stack duplicate handlers).
    @_tool_tip_wired = false

    # Sets the hover help text. Setting a non-nil value makes the widget
    # mouse-hover-tracked (it begins receiving `Event::MouseEnter`/`MouseLeave`) and
    # shows/hides the tooltip automatically. Set `nil` to disable.
    def tool_tip=(text : String?)
      @tool_tip = text
      wire_tool_tip if text && !@_tool_tip_wired
      text
    end

    # Whether the absolute point (*x*, *y*) lies within this widget's
    # last-laid-out rectangle. Returns false before layout.
    def contains_point?(x : Int32, y : Int32) : Bool
      # Prefer the painted rectangle: it carries the margin shift,
      # enclosing-scroll offset and clipping, so a scrolled or clipped widget is
      # tested where it actually appears (and one painted to nothing is never
      # contained). Fall back to the computed rectangle only before the first
      # render; `aleft` may raise pre-layout, hence the rescue.
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
    # region* — the points that still interact while this widget is grabbing
    # input. Default is the widget's own rectangle; pop-ups owning extra area
    # (drop-downs, submenus) override this.
    def grab_contains?(x : Int32, y : Int32) : Bool
      contains_point? x, y
    end

    # Hides the shown tooltip. Qt's `QToolTip::hideText`. Does not clear
    # `#tool_tip`; the text stays and pops up again on the next hover.
    def hide_tool_tip
      @_tool_tip.try &.hide
      # Render the tooltip's OWN window, not the widget's: after a cross-window
      # reparent the tooltip may still live on the window it was created on, and
      # `Widget#hide` schedules no render itself — so the old surface would keep
      # showing the tooltip frame if we only re-rendered the widget's window.
      @_tool_tip.try &.window?.try &.update
    end

    private def wire_tool_tip : Nil
      @_tool_tip_wired = true
      on(Crysterm::Event::MouseEnter) { |e| show_tool_tip e.x, e.y }
      on(Crysterm::Event::MouseLeave) { hide_tool_tip }
      # A hidden widget must not leave its tooltip lingering.
      on(Crysterm::Event::Hide) { hide_tool_tip }
    end

    # The GUI mouse-pointer shape requested while the pointer is over this widget
    # — e.g. `::Tput::MouseCursorShape::PointingHandCursor` for a clickable
    # widget. `nil` leaves the pointer unchanged.
    #
    # Honored only when `Window#mouse_cursor_shaping?` (the `mouse.cursor_shape`
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
      on(Crysterm::Event::MouseEnter) do
        @mouse_cursor_shape.try { |shape| window?.try(&.mouse_cursor_shape=(shape)) }
      end
      on(Crysterm::Event::MouseLeave) { window?.try(&.mouse_cursor_shape=(nil)) }
      # If hidden while it owns the pointer shape, restore the default: no
      # `MouseLeave` fires for a widget that vanishes under the pointer.
      on(Crysterm::Event::Hide) do
        s = window?
        s.mouse_cursor_shape = nil if s && s.hovered == self
      end
    end

    # Shows the tooltip (Qt's `QToolTip::showText`), creating it lazily on
    # first hover. Public for symmetry with `#hide_tool_tip`.
    def show_tool_tip(x : Int32, y : Int32) : Nil
      text = @tool_tip
      return unless text && !text.empty?
      return unless s = window?
      # A cross-window reparent strands the cached tooltip on the old window (it
      # is a *satellite* window child, not ours), so reusing it would pop the
      # tip up on the wrong surface at this window's coordinates. Drop the stale
      # tooltip and let the lazy-create below rebuild it on the current window.
      @_tool_tip = refresh_satellite(@_tool_tip)
      tip = (@_tool_tip ||= begin
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

    def draggable=(draggable : Bool) : Bool
      draggable ? enable_drag : disable_drag
    end

    # Whether a `#draggable?` source self-moves ("reposition", the default) or
    # stays put and hands a payload to a drop target instead ("transfer").
    # Qt has no direct analogue; consulted the first time `#draggable=` (via
    # the private `#enable_drag`) installs the drag handlers.
    enum DragMode
      Reposition
      Transfer
    end

    # Set this *before* `self.draggable = true` for a **data-transfer** source
    # — one that stays put and hands a payload to a drop target instead of
    # self-moving; fill `data` in your own `Event::DragStart` handler and react
    # in `Event::DragEnd`/`Event::Drop`.
    property drag_mode : DragMode = DragMode::Reposition

    # Grab offset captured at `DragStart`, so a reposition keeps the grabbed
    # point under the pointer rather than snapping the corner to it.
    @_drag_dx = 0
    @_drag_dy = 0

    # Whether the default reposition handlers have been installed (so toggling
    # `draggable` repeatedly doesn't stack duplicate handlers).
    @_drag_reposition_installed = false

    # Marks the widget as a drag source (Qt has no direct analogue). By
    # default also installs **reposition** behavior: while dragged (mouse or
    # keyboard) the widget follows the anchor by editing its own `left`/`top`
    # ("self-move", matching Blessed's `enableDrag`).
    #
    # With `#drag_mode` set to `Transfer` it instead stays put and hands a
    # payload to a drop target — fill `data` in your own `Event::DragStart`
    # handler and react in `Event::DragEnd`/`Event::Drop`.
    private def enable_drag : Bool
      @draggable = true

      if drag_mode.reposition? && !@_drag_reposition_installed
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
    # since `aleft == window.ileft + left`. Used by the drag
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
      drag_max c.awidth, c.ihorizontal, awidth
    end

    protected def drag_max_top : Int32
      c = parent_or_window
      drag_max c.aheight, c.ivertical, aheight
    end

    # Largest in-bounds drag position along one axis: the container's inner
    # content extent (`extent - inset`) minus this widget's own extent, floored
    # at 0 so a widget larger than its container can't produce a negative bound.
    private def drag_max(container_extent, container_inset, own_extent) : Int32
      {container_extent - container_inset - own_extent, 0}.max
    end

    # Whether this widget self-moves while dragged (reposition behavior
    # installed). A transfer-only source (`#drag_mode` set to `Transfer`
    # before `#draggable=` was set) returns false, which the engine uses to
    # decide whether to float a drag "ghost".
    def drag_repositions? : Bool
      @_drag_reposition_installed
    end

    private def disable_drag : Bool
      @draggable = false
    end

    # :nodoc:
    # no-op in this place. `Mixin::TextEditing` (and `LineEdit`) override it
    # publicly — placing the caret is part of an editable widget's API.
    protected def _update_cursor(arg)
    end
  end
end
