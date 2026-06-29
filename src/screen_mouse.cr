module Crysterm
  class Window
    # Surface-side mouse handling — the *hit-test* half: it takes a parsed
    # `::Tput::Mouse::Event` (delivered by the device via `Application#route_input`
    # → `#handle_input`), emits `Event::Mouse` on this surface and on the widget
    # under the pointer, and runs the default focus/click/wheel/hover/drag
    # behaviors. The raw-input half — enabling terminal mouse reporting, the `gpm`
    # daemon reader, and the GUI cursor shape — lives on the device (`Screen`) in
    # `screen_mouse_device.cr`; this surface delegates those (see `window.cr`).

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

    # The widget the pointer is currently hovering over (topmost at the pointer
    # position), used to detect hover in/out transitions.
    @_hover : Widget?

    # The widget currently under the pointer (topmost), or `nil` if none. Useful
    # e.g. to confirm, after a delay, that the pointer is still over a widget.
    def hovered : Widget?
      @_hover
    end

    # The raw mouse transport — terminal reporting (`enable_mouse`/`disable_mouse`),
    # the `gpm` reader (`listen_mouse`), and the GUI cursor shape
    # (`set_mouse_cursor_shape`) — now lives on the device (`Screen`, in
    # `screen_mouse_device.cr`); this surface delegates them (see `window.cr`).

    # Turns off mouse reporting on the device and drops this surface's hover
    # state — `Screen#disable_mouse` handles the terminal/gpm/cursor teardown;
    # the `@_hover` reset is the surface's half (no further `MouseOut` will fire
    # to clear it once reporting is off).
    def disable_mouse : Nil
      @screen.disable_mouse
      @_hover = nil
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
    # is painted (`@children` array order; see `Window#_render`), and the last
    # match wins — i.e. the widget drawn last (on top). This is what makes
    # `Widget#front!` / `Widget#back!` affect which widget the mouse "sees":
    # reordering a widget within its parent's `children` both raises it visually
    # and makes it the hit target, with no separate bookkeeping to keep in sync.
    #
    # `z-index` is layered on top of that tree order: a widget (or any subtree)
    # that declares a `style.z_index` is deferred to a compositing `Plane` and
    # painted *above* the whole base layer, regardless of its position in the
    # tree (see `Window#composite_planes`, which composites every plane over
    # `@lines`). So tree order alone is NOT the paint order once a z-index is in
    # play: a non-z-indexed widget later in the tree must not steal clicks from a
    # z-indexed widget painted on top of it. The hit test therefore ranks each
    # candidate by its effective layer (`hit_layer`) first, and only breaks ties
    # within the same layer by tree order ("last wins").
    def widget_at(x, y, skip : Widget? = nil) : Widget?
      found = nil
      found_key = {0, 0}
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

        # Prefer a higher layer; within the same layer the later (more recently
        # painted) widget wins, so `>=` keeps the historical "last match wins"
        # tie-break for the overwhelmingly common no-z-index case (every key is
        # `{0, 0}`, so this reduces to "last wins", unchanged).
        key = hit_layer el
        if found.nil? || key >= found_key
          found = el
          found_key = key
        end
      end
      found
    end

    # The compositing layer a hit-test candidate is painted into, as a sortable
    # `{plane?, z}` key. `{0, 0}` is the base layer (no `z-index` on the widget
    # or any ancestor); a z-indexed subtree resolves to `{1, z}` — above ANY base
    # widget (the leading `1` beats `0` even for a negative `z`, matching
    # `composite_planes`, which paints every plane over the base) and ordered
    # among other planes by `z`. The nearest self-or-ancestor `z_index` wins,
    # since a z-index defers the whole subtree to one plane.
    private def hit_layer(el : Widget) : Tuple(Int32, Int32)
      e : Widget? = el
      while e
        if z = e.style.z_index
          return {1, z}
        end
        e = e.parent
      end
      {0, 0}
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
      @screen.enable_mouse if @screen._listened_mouse?
    end
  end
end
