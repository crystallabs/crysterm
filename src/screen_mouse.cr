require "gpm"

module Crysterm
  class Screen
    # Mouse support.
    #
    # Crysterm receives mouse input from two possible sources, unified behind a
    # single mechanism:
    #
    #   * **Terminal escape sequences** (xterm SGR/X10) — enabled via `Tput` and
    #     parsed by `Tput::Input#listen`, which hands us a `::Tput::Mouse::Event`.
    #   * **The Linux console `gpm` daemon** — read from `/dev/gpmctl` and
    #     converted to the same `::Tput::Mouse::Event`.
    #
    # Both feed `#dispatch_mouse`, which emits a single `Event::Mouse` on the
    # screen and on the widget under the pointer. Listeners therefore never need
    # to know which source produced an event.

    # Whether mouse listening has been set up for this screen.
    getter? _listened_mouse = false

    # Stack of widgets that have an *input grab* — an open pop-up (menu, combo
    # drop-down, …) that should behave modally: while any grab is active, only
    # points inside a grab's own region (see `Widget#grab_contains?`) deliver
    # hover/click to a widget. Other widgets get no `MouseOver`/`Click` (so e.g. a
    # tooltip never appears under an open menu); the grab's own outside-click
    # dismissal still runs via the screen-level `Event::Mouse`. A stack so nested
    # pop-ups (a combo inside a dialog, a submenu chain) compose.
    @grabs = [] of Widget

    # Registers *w* as an active input grab (no-op if already grabbing).
    def grab(w : Widget) : Nil
      @grabs << w unless @grabs.includes? w
    end

    # Removes *w*'s input grab.
    def ungrab(w : Widget) : Nil
      @grabs.delete w
    end

    # Whether any input grab is active.
    def grabbing? : Bool
      !@grabs.empty?
    end

    # Shared "click-away to dismiss" wiring for anything that opens an overlay —
    # pop-up menus, a `Completer` drop-down, combo lists, … Installs a
    # screen-level watcher that calls *dismiss* on a mouse press whose position
    # *inside* reports as outside it (returns `false`); returns the handler so the
    # owner can remove it (via `#off`) when the overlay goes away. Centralizing it
    # keeps the dismissal behavior identical across every such widget.
    #
    # ```
    # @ev_outside = screen.on_press_outside(->(x : Int32, y : Int32) { contains? x, y }) { close }
    # ```
    def on_press_outside(inside : Proc(Int32, Int32, Bool), &dismiss : -> Nil) : Crysterm::Event::Mouse::Wrapper
      on(Crysterm::Event::Mouse) do |e|
        dismiss.call if e.action.down? && !inside.call(e.x, e.y)
      end
    end

    # Whether the point (*x*, *y*) lies inside some active grab's region (so the
    # pointer should interact normally there). True when nothing is grabbing.
    private def within_grab?(x : Int32, y : Int32) : Bool
      return true if @grabs.empty?
      @grabs.any? &.grab_contains?(x, y)
    end

    # Connection to the `gpm` daemon, if one was established.
    @_gpm : GPM? = nil
    @_gpm_fiber : Fiber?

    # The widget the pointer is currently hovering over (topmost at the pointer
    # position), used to detect hover in/out transitions.
    @_hover : Widget?

    # The widget currently under the pointer (topmost), or `nil` if none. Useful
    # e.g. to confirm, after a delay, that the pointer is still over a widget.
    def hovered : Widget?
      @_hover
    end

    # Whether widgets may change the GUI mouse-pointer shape (xterm's OSC 22)
    # while hovered. Defaults to the `mouse.cursor_shape` config option (off);
    # set per-screen to override. See `Widget#mouse_cursor_shape=`.
    property? mouse_cursor_shape : Bool = Config.mouse_cursor_shape

    # The GUI mouse-pointer shape currently pushed to the terminal via OSC 22, or
    # `nil` for the terminal default. Tracked so we only emit on an actual change
    # and can restore the default on teardown.
    @_mouse_cursor_shape : ::Tput::MouseCursorShape? = nil

    # Requests the GUI mouse-pointer (the windowing-system cursor) take *shape*
    # while it is over this terminal, or restores the terminal default when
    # *shape* is `nil`. A no-op unless `#mouse_cursor_shape?` (the
    # `mouse.cursor_shape` gate) is on, and a no-op when the request matches what
    # is already applied. Best-effort: only xterm-class terminals honor OSC 22
    # (see `::Tput::Output#mouse_cursor_shape`); elsewhere it is silently ignored.
    #
    # Widgets drive this on hover in/out via `Widget#mouse_cursor_shape=`; it can
    # also be called directly to set a screen-wide pointer shape.
    def set_mouse_cursor_shape(shape : ::Tput::MouseCursorShape?) : Nil
      return unless mouse_cursor_shape?
      return if shape == @_mouse_cursor_shape
      @_mouse_cursor_shape = shape
      if shape
        tput.mouse_cursor_shape shape
      else
        tput.reset_mouse_cursor_shape
      end
    end

    # Turns on xterm mouse reporting for this screen's terminal.
    def enable_mouse
      tput.enable_mouse
    end

    # Turns off xterm mouse reporting and disconnects from `gpm` (if connected).
    def disable_mouse
      tput.disable_mouse
      @_gpm.try &.stop
      @_gpm = nil
      # Also drop the fiber handle. Stopping the daemon ends `get_event`'s loop,
      # so the fiber terminates on its own — but `listen_gpm` guards on
      # `@_gpm_fiber` being nil, so leaving the (now-dead) handle set would make a
      # later `listen_mouse` (e.g. after a disconnect/reattach, or any leave→listen
      # cycle) silently skip re-establishing the gpm connection.
      @_gpm_fiber = nil
      # Drop any lingering hover state so a widget isn't left "hovered".
      @_hover = nil
      # With reporting off there will be no further `MouseOut` to revert a
      # hover-set pointer shape, so restore the terminal default now — otherwise
      # the GUI pointer could stay stuck in a widget's shape after teardown.
      set_mouse_cursor_shape nil
    end

    # Sets up mouse listening: enables terminal mouse reporting and, when
    # available, also starts reading from the `gpm` console daemon. Both sources
    # are routed through `#dispatch_mouse`.
    #
    # The terminal escape-sequence reports are consumed by the existing input
    # fiber (`#listen_keys`), so this method does not spawn a fiber for them.
    def listen_mouse
      return if @_listened_mouse
      @_listened_mouse = true

      enable_mouse
      listen_gpm
    end

    # Attempts to connect to the `gpm` daemon and, on success, spawns a fiber
    # that converts each `GPM::Event` into a `::Tput::Mouse::Event` and
    # dispatches it. If `gpm` is unavailable (not a Linux console, daemon not
    # running, no socket), this silently does nothing — the terminal
    # escape-sequence path remains fully functional.
    private def listen_gpm
      return if @_gpm_fiber

      gpm = begin
        GPM.new
      rescue
        nil
      end
      return unless gpm

      @_gpm = gpm
      @_gpm_fiber = spawn do
        while e = gpm.get_event
          dispatch_mouse gpm_to_event(e)
        end
      end
    end

    # Converts a `GPM::Event` (Linux console mouse) into the normalized
    # `::Tput::Mouse::Event`. GPM coordinates are 1-based; we shift them to the
    # 0-based convention used throughout mouse handling.
    private def gpm_to_event(e : GPM::Event) : ::Tput::Mouse::Event
      button = if e.left?
                 ::Tput::Mouse::Button::Left
               elsif e.middle?
                 ::Tput::Mouse::Button::Middle
               elsif e.right?
                 ::Tput::Mouse::Button::Right
               else
                 ::Tput::Mouse::Button::None
               end

      action = if e.wheel_up?
                 ::Tput::Mouse::Action::WheelUp
               elsif e.wheel_down?
                 ::Tput::Mouse::Action::WheelDown
               elsif e.released?
                 ::Tput::Mouse::Action::Up
               elsif e.pressed?
                 ::Tput::Mouse::Action::Down
               else
                 # MOVE or DRAG (or anything else) is reported as movement.
                 ::Tput::Mouse::Action::Move
               end

      ::Tput::Mouse::Event.new(
        action, button,
        (e.x - 1).to_i, (e.y - 1).to_i,
        e.shift?, e.meta?, e.ctrl?, :gpm
      )
    end

    # The single dispatch point for *all* mouse events, regardless of source.
    #
    # Emits an `Event::Mouse` on the screen, then locates the topmost
    # mouse-responsive widget under the pointer (`#widget_at`). If one is found,
    # it emits an `Event::Mouse` on it and then — unless a listener `#accept`ed
    # that event — applies the default, out-of-the-box behaviors:
    #
    #   * **Button press** (`action.down?`) focuses the widget (when it is
    #     focusable and `focus_on_click?`) and emits an `Event::Click`.
    #   * **Wheel** (`action.wheel_up?`/`wheel_down?`) scrolls the widget, or its
    #     nearest scrollable ancestor.
    #
    # A widget that wants to override a default can simply `accept` the
    # `Event::Mouse` in its own handler.
    def dispatch_mouse(ev : ::Tput::Mouse::Event)
      # Splat form (`emit type, *args`) so the `Mouse` event object is built only
      # when a screen-level listener exists — mouse reports (especially motion)
      # are high-frequency, and most carry no screen-level subscriber. The
      # explicit-object form `emit Mouse.new(ev)` would allocate unconditionally.
      emit ::Crysterm::Event::Mouse, ev

      # Focus in/out reports (mode 1004) come through the same channel but carry
      # no pointer position; surface them on the screen, then stop before the
      # widget hit-testing / drag machinery below.
      return if ev.focus_event?

      # An in-flight (mouse-driven) drag captures all motion/release: it owns the
      # pointer until released, regardless of what is underneath. A continuous
      # drag ends on button-up; a discrete (two-click) drag ends on the next
      # button-down, retargeting to whatever is under that final click (so it
      # works even on terminals that report no motion at all).
      if drag = @_drag
        if drag.sensor.mouse?
          if ev.action.move?
            drag_motion drag, ev.x, ev.y, ev.shift?, ev.ctrl?
          elsif drag.discrete? ? ev.action.down? : ev.action.up?
            if drag.discrete?
              retarget_over drag, widget_at(ev.x, ev.y, skip: drag.source)
            end
            drag_release drag
          end
        end
        return
      end

      w = widget_at ev.x, ev.y

      # Modal grab: while a pop-up is open, the pointer only interacts with its
      # region. Elsewhere, drop the target so no hover/click reaches other
      # widgets (the pop-up's outside-click dismissal already ran via the
      # screen-level `Event::Mouse` emitted above).
      w = nil unless within_grab? ev.x, ev.y

      update_hover w, ev

      # Press over a draggable widget. In two-click mode the press lifts it
      # immediately (the fallback for terminals with no motion reporting);
      # otherwise we merely *arm* and wait for motion, so a plain click still
      # works.
      if ev.action.down? && w && w.draggable?
        if drag_two_click?
          start_drag w, ev.x, ev.y, ::Crysterm::DragSensor::Mouse,
            action: drag_action_for(ev.shift?, ev.ctrl?, ::Crysterm::DragAction::Move),
            discrete: true
          return
        end
        @_arm = w
        @_arm_x = ev.x
        @_arm_y = ev.y
      end

      if armed = @_arm
        if ev.action.move? && (ev.x != @_arm_x || ev.y != @_arm_y)
          # Start the drag from the press point (so the grab offset is correct),
          # then immediately apply this first motion.
          ax, ay = @_arm_x, @_arm_y
          @_arm = nil
          sess = start_drag armed, ax, ay, ::Crysterm::DragSensor::Mouse,
            action: drag_action_for(ev.shift?, ev.ctrl?, ::Crysterm::DragAction::Move)
          drag_motion sess, ev.x, ev.y, ev.shift?, ev.ctrl?
          return
        elsif ev.action.up?
          # No motion: it was a click after all. Draggable widgets emit their
          # click on release (mouse-up semantics) since the press was ambiguous.
          @_arm = nil
          armed.emit ::Crysterm::Event::Click if w == armed
          return
        end
      end

      return unless w

      # A wheel acting on a widget implicitly focuses it, matching GUI toolkits.
      # Done before the widget is offered the event below, so it applies even when
      # the widget consumes the wheel itself (e.g. a `Dial`/`SpinBox`/`Slider`) and
      # to the focusable scrollable ancestor of an item (e.g. a `List`).
      if ev.action.wheel_up? || ev.action.wheel_down?
        if target = focusable_at w
          target.focus
          render
        end
      end

      # Splat form: builds (and returns) the `Mouse` event only if `w` has a
      # listener; `nil` otherwise. A widget with no `Mouse` handler cannot have
      # accepted it, so `me.try(&.accepted?)` correctly falls through to the
      # default focus/click handling below.
      me = w.emit ::Crysterm::Event::Mouse, ev
      if me.try(&.accepted?)
        # A `draggable?` widget that handles the press itself opts out of the
        # default drag, exactly as accepting the event suppresses the
        # focus/click/wheel defaults below. The drag was *armed* above — before
        # the widget got a chance to see (and accept) the event — so clear that
        # arm here; otherwise a later motion would promote this accepted press
        # into a drag, the one default that would otherwise escape `accept`.
        # Scoped to the arming press (`down?` over the armed widget) so an
        # accepted move/up never disturbs an in-progress arm for another widget.
        @_arm = nil if ev.action.down? && @_arm == w
        return
      end

      if ev.action.down?
        # Click-to-focus, the GUI-toolkit default. Only focusable widgets are
        # focused; `focus_on_click?` lets a widget opt out (e.g. list items), and
        # a disabled widget is never focused (it cannot react to keys) — matching
        # Tab navigation (`focus_offset`) and the wheel-focus path (`focusable_at`).
        if w.focus_on_click? && w.keyable? && !w.disabled?
          w.focus
          render
        end
        # A draggable widget defers its click to release (handled above), so it
        # is not also emitted here on press.
        w.emit ::Crysterm::Event::Click unless w.draggable?
      elsif ev.action.wheel_up?
        scroll_under w, -1, horizontal: ev.shift?
      elsif ev.action.wheel_down?
        scroll_under w, 1, horizontal: ev.shift?
      end
    end

    # The nearest widget at or above *w* that can take focus by pointer (it is
    # `keyable?` and has not opted out via `focus_on_click?`), or `nil` if none.
    # Used to resolve which widget a click/wheel implicitly focuses.
    private def focusable_at(w : Widget) : Widget?
      el : Widget? = w
      # A disabled widget is not a focus target (it does not react to keys); skip
      # past it to an enabled focusable ancestor, matching Tab navigation
      # (`focus_offset`) and the click-to-focus guard below.
      while el && !(el.focus_on_click? && el.keyable? && !el.disabled?)
        el = el.parent
      end
      el
    end

    # Scrolls the first scrollable widget at or above *w* by *offset* — vertically
    # by lines, or (Shift + wheel) *horizontal*ly by columns — and re-renders.
    # No-op if neither *w* nor any ancestor is scrollable.
    private def scroll_under(w : Widget, offset : Int32, horizontal = false)
      el : Widget? = w
      while el && !el.scrollable?
        el = el.parent
      end
      return unless el
      horizontal ? el.scroll_x(offset) : el.scroll(offset)
      render
    end

    # Emits hover transition events for the topmost widget under the pointer.
    #
    # We deliberately notify only the topmost widget (*w*): a hover is a visual,
    # foreground notion, so an occluded widget should not appear hovered. A
    # widget that nonetheless wants to know about activity while in the
    # background can subscribe to the screen-level `Event::Mouse`.
    #
    #   * Entering a widget       -> `Event::MouseOver` on it.
    #   * Leaving the prior one   -> `Event::MouseOut`  on it.
    #   * Moving while staying on  -> `Event::MouseMove` (hovering) on it.
    private def update_hover(w : Widget?, ev : ::Tput::Mouse::Event)
      # Splat form so the hover event objects are built only when the widget
      # actually subscribes to that hover transition. These fire on pointer
      # movement, so the common (no hover handler) case is now allocation-free.
      if w != @_hover
        if old = @_hover
          old.emit ::Crysterm::Event::MouseOut, ev
        end
        @_hover = w
        if w
          w.emit ::Crysterm::Event::MouseOver, ev
        end
      elsif w && ev.action.move?
        w.emit ::Crysterm::Event::MouseMove, ev
      end
    end

    # Returns the topmost visible, mouse-responsive widget whose absolute
    # rectangle contains the 0-based point (*x*, *y*), or `nil` if none.
    #
    # Hit-testing follows the actual render/z order rather than registration
    # order: the widget tree is walked in the same depth-first order in which it
    # is painted (`@children` array order; see `Screen#_render`), and the last
    # match wins — i.e. the widget drawn last (on top). This is what makes
    # `Widget#front!` / `Widget#back!` affect which widget the mouse "sees":
    # reordering a widget within its parent's `children` both raises it visually
    # and makes it the hit target, with no separate bookkeeping to keep in sync.
    def widget_at(x, y, skip : Widget? = nil) : Widget?
      found = nil
      each_descendant do |el|
        next if skip && el == skip
        # The transient drag ghost is decorative and must never be a drop target.
        next if (g = @_drag_ghost) && el == g
        next unless el.wants_mouse?
        # `#visible?` only reflects the widget's own flag, not its ancestors' — so
        # a "shown" widget inside a hidden container (e.g. a page of a tab that is
        # not the current one) would otherwise still be hit-tested and could
        # intercept clicks meant for the visible content at the same coordinates.
        # Require the whole chain to be visible.
        next unless displayed_in_tree? el

        left = el.aleft
        top = el.atop
        next unless x >= left && x < left + el.awidth
        next unless y >= top && y < top + el.aheight

        found = el
      end
      found
    end

    # Whether *el* and every ancestor up the parent chain are visible — i.e. the
    # widget is actually on screen, not merely flagged visible while sitting in a
    # hidden container.
    private def displayed_in_tree?(el : Widget) : Bool
      shown = true
      el.self_and_each_ancestor { |a| shown = false unless a.style.visible? }
      shown
    end

    # Registers *el* as a widget that wants to receive mouse input. Mirrors
    # `#register_keyable`. If mouse listening is already active, this lazily
    # ensures terminal mouse reporting is on (blessed-style on-demand enabling).
    def register_clickable(el : Widget)
      return if @clickable.includes? el
      el.clickable = true
      @clickable.push el
      enable_mouse if @_listened_mouse
    end
  end
end
