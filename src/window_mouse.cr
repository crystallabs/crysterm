require "./macros"

module Crysterm
  class Window
    include Macros

    # Surface-side mouse handling — the *hit-test* half: takes a parsed
    # `::Tput::Mouse::Event` (delivered by the device via `Application#route_input`
    # → `#handle_input`), emits `Event::Mouse` on this surface and on the widget
    # under the pointer, and runs the default focus/click/wheel/hover/drag
    # behaviors. The raw-input half (terminal mouse reporting, `gpm` reader, GUI
    # cursor shape) lives on the device (`Screen`, in `screen_mouse_device.cr`);
    # this surface delegates to it (see `window.cr`).

    # Stack of widgets with an *input grab* — an open pop-up (menu, combo
    # drop-down, …) behaving modally: while any grab is active, only points
    # inside a grab's own region (`Widget#grab_contains?`) deliver hover/click.
    # Other widgets get no `MouseOver`/`Click` (so a tooltip never appears under
    # an open menu); the grab's outside-click dismissal still runs via the
    # screen-level `Event::Mouse`. Stacked so nested pop-ups compose.
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

    # Shared "click-away to dismiss" wiring for anything that opens an overlay
    # (pop-up menus, a `Completer` drop-down, combo lists, …). Installs a
    # screen-level watcher that calls *dismiss* on a mouse press whose position
    # *inside* reports as outside it (returns `false`); returns the handler so
    # the owner can remove it (via `#off`) when the overlay goes away.
    #
    # ```
    # @ev_outside = screen.on_press_outside(->(x : Int32, y : Int32) { contains? x, y }) { close }
    # ```
    def on_press_outside(inside : Proc(Int32, Int32, Bool), &dismiss : -> Nil) : Crysterm::Event::Mouse::Wrapper
      on(Crysterm::Event::Mouse) do |e|
        dismiss.call if e.action.down? && !inside.call(e.x, e.y)
      end
    end

    # Whether the point (*x*, *y*) lies inside some active grab's region. True
    # when nothing is grabbing.
    private def within_grab?(x : Int32, y : Int32) : Bool
      return true if @grabs.empty?
      @grabs.any? &.grab_contains?(x, y)
    end

    # A disabled widget under the pointer receives no interaction events
    # (press/release/motion): hit-testing still returns it (so click-to-focus is
    # suppressed and a scrollable ancestor can still take the wheel), but it never
    # sees `Event::Mouse`/`Event::Click`, mirroring the keyboard path (a disabled
    # widget can't hold focus, so never gets `on_keypress`).
    private def disabled_interaction?(w : Widget, ev : ::Tput::Mouse::Event) : Bool
      w.disabled? && (ev.action.down? || ev.action.up? || ev.action.move?)
    end

    # Widget the pointer is currently hovering over (topmost), used to detect
    # hover in/out transitions.
    @_hover : Widget?

    # The widget currently under the pointer (topmost), or `nil`.
    def hovered : Widget?
      @_hover
    end

    # Number of consecutive presses on the same widget at the same spot within
    # `Config.mouse_double_click_interval` of each other: `1` for a single
    # click, `2` for a double, `3`+ for triple and beyond. Valid to read from
    # within a widget's `Event::Mouse`/`Event::Click` handler for the current
    # press (computed by `#dispatch_mouse` before the widget is notified). See
    # `Mixin::TextEditing`'s word/line select.
    getter click_count : Int32 = 0

    @_last_click_at : Time::Instant?
    @_last_click_pos : Tuple(Int32, Int32)?
    @_last_click_target : Widget?
    @_last_click_button : ::Tput::Mouse::Button?

    # Advances `#click_count` for a press of *button* by *w* at (*x*, *y*):
    # increments when this press is close enough in time
    # (`Config.mouse_double_click_interval`) and position (same cell) to the
    # previous one on the same widget — **with the same button**, so a
    # right-then-left pair never reads as a double left click — else resets to
    # 1. `now` is the caller's instant timestamp so a single press reads the
    # clock once.
    private def bump_click_count(w : Widget?, x : Int32, y : Int32, button : ::Tput::Mouse::Button, now : Time::Instant) : Nil
      within = @_last_click_at.try { |t| now - t <= Config.mouse_double_click_interval } || false
      same = @_last_click_target == w && @_last_click_pos == {x, y} && @_last_click_button == button
      @click_count = within && same ? @click_count + 1 : 1
      @_last_click_at = now
      @_last_click_pos = {x, y}
      @_last_click_target = w
      @_last_click_button = button
    end

    # Clears the running click-count state so the next press starts fresh at 1.
    # Used when a press is diverted (e.g. into a two-click drag) and never
    # becomes an `Event::Click`, so it must not chain into a later click's
    # double/triple detection.
    private def reset_click_count : Nil
      @click_count = 0
      @_last_click_at = nil
      @_last_click_pos = nil
      @_last_click_target = nil
      @_last_click_button = nil
    end

    # Widget that has captured the mouse: while set, all subsequent motion and
    # release reports route to it (via `Event::Mouse`) regardless of what's
    # under the pointer, and the release clears the capture. Lets a widget keep
    # receiving a press-drag it started even after the pointer leaves its bounds
    # (e.g. `Mixin::TextEditing` extending a selection past the edge) — the
    # lightweight, self-managed counterpart of the `draggable?` drag machinery.
    @_mouse_captor : Widget?

    # Button that armed the current mouse capture — the button of the press
    # being dispatched when `#capture_mouse` ran. Only a release of *this*
    # button (or a buttonless legacy release) ends the capture, so tapping
    # another button mid-drag-select can't cut the capture short.
    @_mouse_captor_button : ::Tput::Mouse::Button?

    # Button of the most recent press dispatched (`nil` before any press).
    # Lets `#capture_mouse`, called from inside a widget's press handler,
    # record which button armed the capture.
    @_dispatching_button : ::Tput::Mouse::Button?

    # Directs subsequent mouse motion/release to *w* until the button is
    # released (or `#release_mouse`). Called by a widget from its own press
    # handler.
    def capture_mouse(w : Widget) : Nil
      @_mouse_captor = w
      @_mouse_captor_button = @_dispatching_button
    end

    # Ends any active mouse capture (see `#capture_mouse`).
    def release_mouse : Nil
      @_mouse_captor = nil
      @_mouse_captor_button = nil
    end

    # Per-Window pooled mouse events (one per concrete class), reused across
    # dispatches so a mouse report doesn't heap-allocate a fresh event object
    # every time while a listener is installed — a screen-level `Event::Mouse`
    # listener is routine (every pop-up/menu/combo installs one via
    # `#on_press_outside`), and mouse motion is high-frequency. See
    # `Event::Mouse#reset` for the retention caveat.
    pooled_mouse_event mouse, Mouse
    pooled_mouse_event mouse_over, MouseOver
    pooled_mouse_event mouse_move, MouseMove
    pooled_mouse_event mouse_out, MouseOut

    # The raw mouse transport (terminal reporting, `gpm` reader, GUI cursor
    # shape) lives on the device (`Screen`, in `screen_mouse_device.cr`); this
    # surface delegates to it (see `window.cr`).

    # Turns off mouse reporting on the device and drops this surface's hover
    # state — `Screen#disable_mouse` handles terminal/gpm/cursor teardown; the
    # `@_hover` reset is the surface's half (no further `MouseOut` fires once
    # reporting is off).
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
    # Inline mode: the device reports rows in physical terminal coordinates,
    # but the surface (widgets, hit-test) lives in `[0, aheight)` at physical
    # rows `[offset, offset + aheight)`. Translate the pointer back into
    # surface space so hover/click/drag land on the right cell. `ev` is a
    # by-value struct, so the returned copy is adjusted; a no-op when the
    # offset is 0 (full-screen mode).
    private def translate_inline_mouse(ev : ::Tput::Mouse::Event)
      if (off = render_row_offset) != 0
        ev.y -= off
      end
      ev
    end

    def dispatch_mouse(ev : ::Tput::Mouse::Event)
      ev = translate_inline_mouse ev

      # Reuse the pooled `Mouse` event (reset in place) instead of allocating a
      # fresh object per report — a screen-level listener is routine, and mouse
      # reports (especially motion) are high-frequency. `emit(type, event)`
      # still early-outs when nothing is subscribed.
      emit ::Crysterm::Event::Mouse, mouse_event(ev)

      # Focus in/out reports (mode 1004) share this channel but carry no
      # pointer position; surface on the screen and stop before hit-testing.
      return if ev.focus_event?

      # A widget that captured the mouse or an in-flight drag consumes all
      # motion/release regardless of the pointer's position; if either claims
      # this event we're done. Capture is checked first since it's the lighter
      # mechanism a non-`draggable?` widget opts into.
      return if handle_mouse_captor ev
      return if handle_active_drag ev

      w = widget_at ev.x, ev.y

      # Modal grab: while a pop-up is open, the pointer only interacts with its
      # region; elsewhere drop the target (outside-click dismissal already ran
      # via the screen-level `Event::Mouse` above).
      w = nil unless within_grab? ev.x, ev.y

      # Resolve the click count before the target sees the press, so a widget's
      # own `Event::Mouse`/`Event::Click` handler can read `#click_count` for
      # this press (double/triple detection). Only a real button press counts;
      # motion/release/wheel leave the running count alone.
      if ev.action.down?
        bump_click_count(w, ev.x, ev.y, ev.button, Time.instant)
        # Remember which button this press dispatch carries, so a widget press
        # handler calling `#capture_mouse` records the arming button.
        @_dispatching_button = ev.button
      end

      update_hover w, ev

      # Press over a draggable widget. Two-click mode lifts it immediately
      # (fallback for terminals with no motion reporting); otherwise *arm* and
      # wait for motion, so a plain click still works.
      if ev.action.down? && w && w.draggable? && !w.disabled?
        if drag_two_click?
          # This press is consumed by the two-click drag and never reaches the
          # widget as an `Event::Click`, so undo the count bumped above —
          # otherwise a later real click on the same spot/widget within the
          # double-click interval would read an inflated `#click_count`.
          reset_click_count
          # Record the lifting button so only its release/press terminates the
          # gesture (see `handle_active_drag`).
          @_drag_button = ev.button
          start_drag w, ev.x, ev.y, ::Crysterm::DragSensor::Mouse,
            action: drag_action_for(ev.shift?, ev.ctrl?, ::Crysterm::DragAction::Move),
            discrete: true
          return
        end
        @_arm = w
        @_arm_x = ev.x
        @_arm_y = ev.y
        @_arm_button = ev.button
      end

      if armed = @_arm
        if ev.action.move? && (ev.x != @_arm_x || ev.y != @_arm_y)
          # Start the drag from the press point (correct grab offset), then
          # apply this first motion immediately.
          ax, ay = @_arm_x, @_arm_y
          @_arm = nil
          # The arming press is consumed by this drag and never reaches the
          # widget as an `Event::Click`, so undo the count bumped on `down` —
          # otherwise a later real click on the same spot within the
          # double-click interval would read an inflated `#click_count`
          # (mirrors the two-click-drag branch above).
          reset_click_count
          # The drag commits only on the ARMING press's button (see
          # `handle_active_drag`).
          @_drag_button = @_arm_button
          sess = start_drag armed, ax, ay, ::Crysterm::DragSensor::Mouse,
            action: drag_action_for(ev.shift?, ev.ctrl?, ::Crysterm::DragAction::Move)
          drag_motion sess, ev.x, ev.y, ev.shift?, ev.ctrl?
          return
        elsif ev.action.up?
          # No motion: it was a click after all. Draggable widgets emit their
          # click on release since the press was ambiguous.
          @_arm = nil
          armed.emit ::Crysterm::Event::Click if w == armed && !armed.disabled?
          return
        end
      end

      return unless w

      # A wheel acting on a widget implicitly focuses it, matching GUI toolkits.
      # Done before the widget sees the event, so it applies even when the
      # widget consumes the wheel itself (e.g. `Dial`/`SpinBox`/`Slider`) or via
      # a focusable scrollable ancestor (e.g. a `List`).
      if ev.action.wheel_up? || ev.action.wheel_down?
        if target = focusable_at w
          target.focus
          render
        end
      end

      # A disabled widget under the pointer takes no press/release/motion (see
      # `#disabled_interaction?`).
      return if disabled_interaction? w, ev

      # Reuse the pooled `Mouse` event. `emit(type, event)` returns it
      # regardless of listeners, but `reset` cleared `accepted`, so with no
      # handler (or a handler that didn't `accept`) `me.accepted?` is false and
      # we correctly fall through to the default handling below.
      me = w.emit ::Crysterm::Event::Mouse, mouse_event(ev)
      if me.accepted?
        # A `draggable?` widget handling the press itself opts out of the
        # default drag. The drag was *armed* above, before the widget could
        # accept the event, so clear it here — otherwise a later motion would
        # promote this accepted press into a drag despite `accept`. Scoped to
        # the arming press so an accepted move/up doesn't disturb another
        # widget's in-progress arm.
        @_arm = nil if ev.action.down? && @_arm == w
        return
      end

      if ev.action.down?
        # Click-to-focus, the GUI-toolkit default. `focus_on_click?` lets a
        # widget opt out (e.g. list items); a disabled widget is never focused,
        # matching Tab navigation (`focus_offset`) and `focusable_at`.
        if w.focus_on_click? && w.keyable? && !w.disabled?
          w.focus
          render
        end
        # A draggable widget defers its click to release (handled above).
        w.emit ::Crysterm::Event::Click unless w.draggable?
      elsif ev.action.wheel_up?
        scroll_under w, -1, horizontal: ev.shift?
      elsif ev.action.wheel_down?
        scroll_under w, 1, horizontal: ev.shift?
      end
    end

    # A widget that captured the mouse (`#capture_mouse`) receives all motion
    # and release regardless of the pointer's position, so a press-drag it
    # started keeps flowing after the pointer leaves its bounds. The release
    # ends the capture. A down clears the capture and falls through to normal
    # hit-testing (a fresh press retargets) — this also recovers if the
    # matching release was lost, else the stale captor would eat all motion
    # forever. Returns whether the event was consumed.
    private def handle_mouse_captor(ev : ::Tput::Mouse::Event) : Bool
      captor = @_mouse_captor
      return false unless captor
      if ev.action.move?
        captor.emit ::Crysterm::Event::Mouse, mouse_event(ev)
        return true
      elsif ev.action.up?
        captor.emit ::Crysterm::Event::Mouse, mouse_event(ev)
        # Only the ARMING button's release (or a buttonless legacy release)
        # ends the capture — a stray other-button tap mid-gesture must not cut
        # a drag-select short.
        if gesture_end_button?(ev.button, @_mouse_captor_button)
          release_mouse
        end
        return true
      elsif ev.action.down?
        if gesture_end_button?(ev.button, @_mouse_captor_button)
          # A fresh press of the capture button implies the matching release
          # was lost: clear and fall through so the press retargets normally
          # (else the stale captor would eat all motion forever).
          release_mouse
        else
          # Another button pressed mid-capture: swallow it (mirrors the
          # in-flight drag, where a non-arming button's press is consumed).
          return true
        end
      end
      false
    end

    # Whether a press/release of *button* terminates a gesture armed by
    # *armed*: the buttons match, the report carries no button (legacy
    # encodings release with `Button::None`), or no arming button was recorded.
    private def gesture_end_button?(button : ::Tput::Mouse::Button, armed : ::Tput::Mouse::Button?) : Bool
      armed.nil? || button == armed || button.none?
    end

    # An in-flight drag captures all motion/release regardless of what's
    # underneath. A continuous drag ends on button-up; a discrete (two-click)
    # drag ends on the next button-down, retargeting to whatever's under that
    # click (works even without motion reporting). Returns whether an active
    # drag consumed the event.
    private def handle_active_drag(ev : ::Tput::Mouse::Event) : Bool
      drag = @_drag
      return false unless drag
      # A non-mouse (e.g. keyboard) drag targets the *focused* widget, not the
      # pointer. Consuming pointer events here would starve hover/click/wheel
      # dispatch to widgets for the whole duration of the drag, so let them
      # flow through; only a mouse-sensor drag owns the pointer stream.
      return false unless drag.sensor.mouse?
      if ev.action.move?
        drag_motion drag, ev.x, ev.y, ev.shift?, ev.ctrl?
      elsif drag.discrete? ? ev.action.down? : (ev.action.up? && gesture_end_button?(ev.button, @_drag_button))
        # A continuous drag commits only on the ARMING button's release (or a
        # buttonless legacy release) — an RMB tap mid-LMB-drag used to commit
        # the Drop at the pointer mid-gesture. Non-matching ups (and any other
        # buttons' downs) are swallowed with the rest of the pointer stream.
        if drag.discrete?
          retarget_over drag, widget_at(ev.x, ev.y, skip: drag.source)
        end
        drag_release drag
      end
      true
    end

    # The nearest widget at or above *w* that can take focus by pointer
    # (`keyable?` and not opted out via `focus_on_click?`), or `nil`.
    private def focusable_at(w : Widget) : Widget?
      # Skip disabled widgets (not a focus target), matching Tab navigation
      # (`focus_offset`) and the click-to-focus guard below.
      w.first_self_or_ancestor { |el| el.focus_on_click? && el.keyable? && !el.disabled? }
    end

    # Scrolls the first scrollable widget at or above *w* by *offset* —
    # vertically by lines, or (Shift + wheel) *horizontal*ly — and re-renders.
    # No-op if neither *w* nor any ancestor is scrollable.
    private def scroll_under(w : Widget, offset : Int32, horizontal = false)
      el = w.first_self_or_ancestor &.scrollable?
      return unless el
      horizontal ? el.scroll_x(offset) : el.scroll(offset)
      render
    end

    # Emits hover transition events for the topmost widget under the pointer.
    #
    # Only the topmost widget (*w*) is notified: hover is a visual, foreground
    # notion, so an occluded widget shouldn't appear hovered. A widget wanting
    # background activity can subscribe to the screen-level `Event::Mouse`.
    #
    #   * Entering a widget        -> `Event::MouseOver` on it.
    #   * Leaving the prior one    -> `Event::MouseOut`  on it.
    #   * Moving while staying on  -> `Event::MouseMove` (hovering) on it.
    private def update_hover(w : Widget?, ev : ::Tput::Mouse::Event)
      # Pooled hover events (reset in place) — `emit(type, event)` still
      # early-outs when unsubscribed, keeping the common (no handler) case
      # allocation-free on pointer movement.
      if w != @_hover
        if old = @_hover
          old.emit ::Crysterm::Event::MouseOut, mouse_out_event(ev)
        end
        @_hover = w
        if w
          w.emit ::Crysterm::Event::MouseOver, mouse_over_event(ev)
        end
      elsif w && ev.action.move?
        w.emit ::Crysterm::Event::MouseMove, mouse_move_event(ev)
      end
    end

    # Returns the topmost visible, mouse-responsive widget whose absolute
    # rectangle contains the 0-based point (*x*, *y*), or `nil` if none.
    #
    # Hit-testing follows render/z order rather than registration order: the
    # tree is walked depth-first in paint order (`@children` array order; see
    # `Window#_render`), and the last match wins (topmost). This is what makes
    # `Widget#front!`/`Widget#back!` affect hit-testing: reordering a widget in
    # its parent's `children` both raises it visually and makes it the hit
    # target, with no separate bookkeeping.
    #
    # `z-index` layers on top of tree order: a subtree with `style.z_index` is
    # deferred to a compositing `Plane` painted *above* the base layer
    # regardless of tree position (see `Window#composite_planes`). So a
    # non-z-indexed widget later in the tree must not steal clicks from a
    # z-indexed widget painted above it — the hit test ranks candidates by
    # effective layer (`hit_layer`) first, breaking ties within a layer by tree
    # order.
    def widget_at(x, y, skip : Widget? = nil) : Widget?
      # Traverse without a captured `Proc`: `each_descendant do |el| … end`
      # reified a heap closure (capturing `found`/`found_key`/`x`/`y`/`skip`)
      # on every call — i.e. every mouse report including all motion. The scan
      # accumulates the best hit in scratch ivars instead; dispatch is
      # single-fiber synchronous, so reusing ivars across the recursion is safe.
      @_hit_found = nil
      @_hit_found_key = {0, 0}
      children.each do |el|
        hit_scan el, x, y, skip
      end
      @_hit_found
    end

    # Scratch state for `#widget_at`'s allocation-free traversal: the best hit
    # so far and its compositing layer key. Only valid for the duration of one
    # synchronous `widget_at` call.
    @_hit_found : Widget?
    @_hit_found_key : Tuple(Int32, Int32) = {0, 0}

    # Pre-order depth-first walk mirroring `Mixin::Children#each_descendant`
    # (visit *el*, then recurse into its children in `@children` order), scoring
    # each widget as a hit-test candidate into `@_hit_found`/`@_hit_found_key`.
    # A widget that fails the candidate test still has its subtree scanned,
    # matching the `each_descendant`/`next` form.
    private def hit_scan(el : Widget, x : Int32, y : Int32, skip : Widget?) : Nil
      if hit_candidate? el, x, y, skip
        # Prefer a higher layer; within the same layer `>=` keeps "last wins"
        # (the common no-z-index case, where every key is `{0, 0}`).
        key = hit_layer el
        if @_hit_found.nil? || key >= @_hit_found_key
          @_hit_found = el
          @_hit_found_key = key
        end
      end
      el.children.each do |c|
        hit_scan c, x, y, skip
      end
    end

    # Whether *el* itself is the topmost-eligible widget occupying (*x*, *y*)
    # under the pointer — the per-widget body of the `widget_at` scan; a failing
    # check `return false`s rather than `next`s. Preserves the exact hit-test order:
    # `lpos` first, then `wants_mouse?`, then whole-chain visibility.
    private def hit_candidate?(el : Widget, x : Int32, y : Int32, skip : Widget?) : Bool
      return false if skip && el == skip
      # The transient drag ghost is decorative, never a drop target.
      return false if (g = @_drag_ghost) && el == g

      # Cheapest check first: hit-test against the widget's *painted* rectangle
      # (`lpos`), not the raw `aleft/atop/awidth/aheight` geometry. `lpos` is
      # what `_render` laid down: it folds in the margin shift AND the
      # enclosing-scroll offset (`base`) and clips to every clipping ancestor's
      # viewport, so a scrolled list item is matched where it actually appears
      # (and a `resizable` widget by its shrunk content box, not the full slot
      # `awidth` reports). Raw geometry would ignore all of that and hit-test
      # scrolled/shrunk children by their unscrolled, unclipped rectangle.
      # `render_children` refreshes every descendant's `lpos` each frame, so it
      # is current once the window has painted.
      lp = el.lpos
      if lp
        return false unless x >= lp.xi && x < lp.xl
        return false unless y >= lp.yi && y < lp.yl
      elsif renders > 0
        # The window has painted but this widget laid down nothing — scrolled or
        # clipped out of view (or not yet rendered since being added). Not a hit.
        return false
      else
        # No paint yet (e.g. a direct `widget_at` before the first render): fall
        # back to raw geometry, since there is no `lpos` to consult.
        left = el.aleft
        top = el.atop
        return false unless x >= left && x < left + el.awidth
        return false unless y >= top && y < top + el.aheight
      end

      return false unless el.wants_mouse?
      # `#visible?` reflects only the widget's own flag, not its ancestors' —
      # require the whole chain visible so a "shown" widget inside a hidden
      # container (e.g. a non-current tab page) can't intercept clicks.
      return false unless displayed_in_tree? el
      true
    end

    # The compositing layer a hit-test candidate is painted into, as a sortable
    # `{plane?, z}` key. `{0, 0}` is the base layer (no `z-index` on the widget
    # or an ancestor); a z-indexed subtree resolves to `{1, z}` — above any base
    # widget (leading `1` beats `0` even for negative `z`, matching
    # `composite_planes`) and ordered among planes by `z`. The OUTERMOST
    # self-or-ancestor `z_index` wins: painting defers only the FIRST z-indexed
    # widget met on the walk down (a nested z-indexed subtree flattens into its
    # enclosing plane — see `compositing_layers?`), so a nested z must not let
    # an occluded widget out-rank the plane it is actually painted into.
    private def hit_layer(el : Widget) : Tuple(Int32, Int32)
      z = nil
      cur : Widget? = el
      while cur
        if zz = cur.style.z_index
          z = zz
        end
        cur = cur.parent
      end
      z ? {1, z} : {0, 0}
    end

    # Whether *el* and every ancestor are visible — i.e. actually on screen, not
    # merely flagged visible while sitting in a hidden container.
    private def displayed_in_tree?(el : Widget) : Bool
      # No self-or-ancestor may be hidden — i.e. no widget in the chain fails
      # the visibility test.
      el.first_self_or_ancestor { |a| !a.style.visible? }.nil?
    end

    # Registers *el* as a widget that wants mouse input. Mirrors
    # `#register_keyable`; lazily ensures terminal mouse reporting is on if
    # mouse listening is already active (blessed-style on-demand enabling).
    def register_clickable(el : Widget)
      return unless register_in el, @clickable
      el.clickable = true
      @screen.enable_mouse if @screen._listened_mouse?
    end
  end
end
