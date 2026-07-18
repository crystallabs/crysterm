require "./macros"

module Crysterm
  class Window
    include Macros

    # Surface-side mouse handling — the *hit-test* half: takes a parsed
    # `::Tput::Mouse::Event` delivered by the device, emits `Event::Mouse` on
    # this surface and on the widget under the pointer, and runs the default
    # focus/click/wheel/hover/drag behaviors. The raw-input half (terminal mouse
    # reporting, `gpm` reader, GUI cursor shape) lives on the device (`Screen`);
    # this surface delegates to it.

    # Stack of widgets with an *input grab* — an open pop-up (menu, combo
    # drop-down, …) behaving modally: while any grab is active, only points
    # inside a grab's own region deliver hover/click. Other widgets get no
    # `MouseEnter`/`Click`, so a tooltip never appears under an open menu; the
    # grab's outside-click dismissal still runs via the screen-level
    # `Event::Mouse`. Stacked so nested pop-ups compose.
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

    # The widget that has currently captured the mouse (`#capture_mouse`), or
    # `nil`. :nodoc: — exposed so the transient-state teardown is observable in
    # tests.
    def mouse_captor : Widget?
      @_mouse_captor
    end

    # Number of consecutive presses on the same widget at the same spot within
    # `Config.mouse_double_click_interval` of each other: `1` for a single
    # click, `2` for a double, `3`+ for triple and beyond. Resolved before the
    # widget is notified, so a widget's `Event::Mouse`/`Event::Click` handler can
    # read it for the current press.
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
    # (e.g. extending a text selection past the edge) — the lightweight,
    # self-managed counterpart of the `draggable?` drag machinery.
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

    # Tears down every transient mouse-interaction pointer that points into the
    # subtree rooted at *subtree* — hover, pending press-arm, mouse captor,
    # in-flight drag source/target, and modal input grabs — bracketing the unlink
    # performed by the yielded block. The stale relations MUST be sampled before
    # the block runs (while the subtree is still relatable via `covers?`) and
    # dropped after, so a removed subtree can never leave this window hovering,
    # capturing, dragging, or modally grabbing a widget no longer on it:
    #
    #   * `@_hover` → next `MouseMove` fires `MouseLeave` on a dead widget, an
    #     OSC-22 pointer shape it set is never reverted (restored here too), and
    #     the subtree is pinned in memory.
    #   * `@_arm` → a later motion calls `start_drag` on a detached widget.
    #   * `@_mouse_captor` → every subsequent Move/Up is swallowed forever (mouse
    #     dead until an unrelated `#release_mouse`).
    #   * `@_drag` source/target → screen stays modally locked / a later `Drop`
    #     fires on an off-screen widget.
    #   * `@grabs` → the modal lock never lifts.
    def release_transient_state_for(subtree : Widget, &) : Nil
      drop_hover = (h = @_hover) && subtree.covers?(h)
      drop_arm = (a = @_arm) && subtree.covers?(a)
      drop_captor = (c = @_mouse_captor) && subtree.covers?(c)
      stale_drag = ((d = @_drag) && subtree.covers?(d.source)) ? d : nil
      stale_target = ((td = @_drag) && (tg = td.target) && subtree.covers?(tg)) ? td : nil
      stale_grabs = @grabs.select { |g| subtree.covers?(g) }

      yield

      @_hover = nil if drop_hover
      self.mouse_cursor_shape = nil if drop_hover
      @_arm = nil if drop_arm
      @_mouse_captor = nil if drop_captor
      stale_drag.try { |sd| drag_cancel sd if @_drag == sd }
      stale_target.try { |st| retarget(st, nil) if @_drag == st }
      stale_grabs.each { |g| ungrab g }
    end

    # Per-Window pooled mouse events (one per concrete class), reused across
    # dispatches so a mouse report doesn't heap-allocate a fresh event object
    # every time while a listener is installed — a screen-level `Event::Mouse`
    # listener is routine (every pop-up/menu/combo installs one), and mouse
    # motion is high-frequency. See `Event::Mouse#reset` for the retention caveat.
    pooled_mouse_event mouse, Mouse
    pooled_mouse_event mouse_over, MouseEnter
    pooled_mouse_event mouse_move, MouseMove
    pooled_mouse_event mouse_out, MouseLeave

    # Turns off mouse reporting on the device and drops this surface's hover
    # state — `Screen#disable_mouse` handles terminal/gpm/cursor teardown; the
    # `@_hover` reset is the surface's half (no further `MouseLeave` fires once
    # reporting is off).
    def disable_mouse : Nil
      @screen.disable_mouse
      @_hover = nil
    end

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

    # The single dispatch point for *all* mouse events, regardless of source.
    #
    # Emits an `Event::Mouse` on the screen, then locates the topmost
    # mouse-responsive widget under the pointer. If one is found, it emits an
    # `Event::Mouse` on it and then — unless a listener `#accept`ed that event —
    # applies the default, out-of-the-box behaviors:
    #
    #   * **Button press** (`action.down?`) focuses the widget (when it is
    #     focusable and `focus_on_click?`) and emits an `Event::Click`.
    #   * **Wheel** (`action.wheel_up?`/`wheel_down?`) scrolls the widget, or its
    #     nearest scrollable ancestor.
    #
    # A widget that wants to override a default can simply `accept` the
    # `Event::Mouse` in its own handler.
    def dispatch_mouse(ev : ::Tput::Mouse::Event)
      ev = translate_inline_mouse ev

      emit ::Crysterm::Event::Mouse, mouse_event(ev)

      # Focus in/out reports (mode 1004) share this channel but carry no
      # pointer position; surface on the screen and stop before hit-testing.
      return if ev.focus_event?

      # A widget that captured the mouse or an in-flight drag consumes all
      # motion/release regardless of the pointer's position.
      return if handle_mouse_captor ev
      return if handle_active_drag ev

      w = widget_at ev.x, ev.y

      # Modal grab: while a pop-up is open, the pointer only interacts with its
      # region; elsewhere drop the target (outside-click dismissal already ran
      # via the screen-level `Event::Mouse` above).
      w = nil unless within_grab? ev.x, ev.y

      # Resolve the click count before the target sees the press. Only a real
      # button press counts; motion/release/wheel leave the running count alone.
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
          # gesture.
          @_drag_button = ev.button
          start_drag w, ev.x, ev.y, ::Crysterm::DragSensor::Mouse,
            action: drag_action_for(ev.shift?, ev.ctrl?, ::Crysterm::DragAction::Move),
            discrete: true
          return
        end
        arm_potential_drag w, ev
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
          # double-click interval would read an inflated `#click_count`.
          reset_click_count
          # The drag commits only on the ARMING press's button; hand it off to
          # `@_drag_button` before clearing the (now resolved) arm.
          @_drag_button = @_arm_button
          @_arm_button = ::Tput::Mouse::Button::None
          sess = start_drag armed, ax, ay, ::Crysterm::DragSensor::Mouse,
            action: drag_action_for(ev.shift?, ev.ctrl?, ::Crysterm::DragAction::Move)
          drag_motion sess, ev.x, ev.y, ev.shift?, ev.ctrl?
          return
        elsif ev.action.up? && gesture_end_button?(ev.button, @_arm_button)
          # No motion: it was a click after all. Draggable widgets emit their
          # click on release since the press was ambiguous. Only the ARMING
          # button's release resolves the arm — a stray other-button up falls
          # through to normal dispatch and leaves the arm intact (mirrors the
          # drag/captor button gating).
          @_arm = nil
          @_arm_button = ::Tput::Mouse::Button::None
          armed.emit ::Crysterm::Event::Click if w == armed && !armed.disabled?
          return
        end
      end

      return unless w

      # A wheel acting on a widget implicitly focuses it, matching GUI toolkits.
      wheel_focuses w, ev

      # A disabled widget under the pointer takes no press/release/motion.
      return if disabled_interaction? w, ev

      # A wheel over a disabled widget routes to a scrollable ancestor instead.
      return if handle_disabled_wheel w, ev

      # `emit(type, event)` returns the pooled event regardless of listeners,
      # and `reset` cleared `accepted`, so with no handler (or one that didn't
      # `accept`) this correctly falls through to the default handling below.
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
        # matching Tab navigation.
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

    # Arm a potential press-and-hold drag on *w*, recording the arming button so
    # only its release/motion resolves the gesture. A different button's press
    # must NOT clobber an arm already pending on another button — the original
    # arming gesture survives until it resolves (mirrors the drag/captor button
    # gating). A same-button (or buttonless) re-press may retarget the arm.
    private def arm_potential_drag(w : Widget, ev : ::Tput::Mouse::Event) : Nil
      return unless @_arm.nil? || gesture_end_button?(ev.button, @_arm_button)
      @_arm = w
      @_arm_x = ev.x
      @_arm_y = ev.y
      @_arm_button = ev.button
    end

    # A wheel acting on a widget implicitly focuses it (matching GUI toolkits),
    # focusing the nearest focusable self-or-ancestor. Done before the widget
    # sees the event, so it applies even when the widget consumes the wheel
    # itself (e.g. `Dial`/`SpinBox`/`Slider`) or via a focusable scrollable
    # ancestor (e.g. a `List`).
    private def wheel_focuses(w : Widget, ev : ::Tput::Mouse::Event) : Nil
      return unless ev.action.wheel_up? || ev.action.wheel_down?
      if target = focusable_at w
        target.focus
        render
      end
    end

    # A wheel over a disabled widget must never reach (or scroll) the widget
    # itself — otherwise a disabled `Dial`/`Slider`/`ScrollBar` mutates its own
    # value on scroll, their ranged-wheel handling having no disabled guard.
    # Only a scrollable *ancestor* may take the wheel, so route the scroll from
    # the parent up. Returns whether the wheel was consumed here.
    private def handle_disabled_wheel(w : Widget, ev : ::Tput::Mouse::Event) : Bool
      return false unless w.disabled? && (ev.action.wheel_up? || ev.action.wheel_down?)
      w.parent.try { |p| scroll_under p, ev.action.wheel_up? ? -1 : 1, horizontal: ev.shift? }
      true
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
      elsif drag.discrete? ? (ev.action.down? && gesture_end_button?(ev.button, @_drag_button)) : (ev.action.up? && gesture_end_button?(ev.button, @_drag_button))
        # Both a continuous drag (commits on button-up) and a discrete two-click
        # drag (commits on the next button-down) commit only on the ARMING
        # button, or a buttonless legacy report; otherwise an RMB tap mid-LMB-drag
        # would commit the Drop at the pointer mid-gesture. Non-matching ups/downs
        # (and any other buttons' presses) are swallowed with the rest of the
        # pointer stream.
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
      # Skip disabled widgets (not a focus target), matching Tab navigation.
      w.first_self_or_ancestor { |el| el.focus_on_click? && el.keyable? && !el.disabled? }
    end

    # Scrolls the first scrollable widget at or above *w* by *offset* —
    # vertically by lines, or (Shift + wheel) *horizontal*ly — and re-renders.
    # No-op if neither *w* nor any ancestor is scrollable.
    private def scroll_under(w : Widget, offset : Int32, horizontal = false)
      el = w.first_self_or_ancestor &.scrollable?
      return unless el
      horizontal ? el.scroll_by_x(offset) : el.scroll(offset)
      render
    end

    # Emits hover transition events for the topmost widget under the pointer.
    #
    # Only the topmost widget (*w*) is notified: hover is a visual, foreground
    # notion, so an occluded widget shouldn't appear hovered. A widget wanting
    # background activity can subscribe to the screen-level `Event::Mouse`.
    #
    #   * Entering a widget        -> `Event::MouseEnter` on it.
    #   * Leaving the prior one    -> `Event::MouseLeave`  on it.
    #   * Moving while staying on  -> `Event::MouseMove` (hovering) on it.
    private def update_hover(w : Widget?, ev : ::Tput::Mouse::Event)
      if w != @_hover
        if old = @_hover
          old.emit ::Crysterm::Event::MouseLeave, mouse_out_event(ev)
        end
        @_hover = w
        if w
          w.emit ::Crysterm::Event::MouseEnter, mouse_over_event(ev)
        end
      elsif w && ev.action.move?
        w.emit ::Crysterm::Event::MouseMove, mouse_move_event(ev)
      end
    end

    # Returns the topmost visible, mouse-responsive widget whose absolute
    # rectangle contains the 0-based point (*x*, *y*), or `nil` if none.
    #
    # Hit-testing follows render/z order rather than registration order: the
    # tree is walked depth-first in paint order (`@children` array order), and
    # the last match wins (topmost). This is what makes `Widget#to_front`/
    # `Widget#to_back` affect hit-testing: reordering a widget in its parent's
    # `children` both raises it visually and makes it the hit target, with no
    # separate bookkeeping.
    #
    # `z-index` layers on top of tree order: a subtree with `style.z_index` is
    # deferred to a compositing `Plane` painted *above* the base layer
    # regardless of tree position. So a non-z-indexed widget later in the tree
    # must not steal clicks from a z-indexed widget painted above it — the hit
    # test ranks candidates by effective layer first, breaking ties within a
    # layer by tree order.
    def widget_at(x, y, skip : Widget? = nil) : Widget?
      # Traverse without a captured `Proc`: an `each_descendant` block would
      # reify a heap closure on every call — i.e. every mouse report, motion
      # included. The scan accumulates the best hit in scratch ivars instead;
      # dispatch is single-fiber synchronous, so reusing them is safe.
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

    # Pre-order depth-first walk (visit *el*, then recurse into its children in
    # `@children` order), scoring each widget as a hit-test candidate into
    # `@_hit_found`/`@_hit_found_key`. A widget that fails the candidate test
    # still has its subtree scanned.
    private def hit_scan(el : Widget, x : Int32, y : Int32, skip : Widget?) : Nil
      if hit_candidate? el, x, y, skip
        # One self-or-ancestor pass yields BOTH whole-chain visibility and the
        # compositing layer key, so this hot motion path walks the parent chain
        # once, not twice. An invisible candidate (a "shown" widget inside a
        # hidden container) is not a hit.
        visible, key = hit_visible_and_layer el
        # Prefer a higher layer; within the same layer `>=` keeps "last wins"
        # (the common no-z-index case, where every key is `{0, 0}`).
        if visible && (@_hit_found.nil? || key >= @_hit_found_key)
          @_hit_found = el
          @_hit_found_key = key
        end
      end
      el.children.each do |c|
        hit_scan c, x, y, skip
      end
    end

    # Whether *el* itself is a hit-test candidate occupying (*x*, *y*) — the
    # per-widget body of the `widget_at` scan; a failing check `return false`s
    # rather than `next`s. Runs the two cheap self-only checks in order (`lpos`
    # first, then `wants_mouse?`); whole-chain visibility is resolved in the
    # merged ancestor pass (`#hit_visible_and_layer`) alongside the layer key,
    # so a passing candidate here is not yet guaranteed on-screen.
    private def hit_candidate?(el : Widget, x : Int32, y : Int32, skip : Widget?) : Bool
      return false if skip && el == skip
      # The transient drag ghost is decorative, never a drop target.
      return false if (g = @_drag_ghost) && el == g

      # Cheapest check first: hit-test against the widget's *painted* rectangle
      # (`lpos`), not the raw `aleft/atop/awidth/aheight` geometry. `lpos` is
      # what `_render` laid down: it folds in the margin shift AND the
      # enclosing-scroll offset (`base`) and clips to every clipping ancestor's
      # viewport, so a scrolled list item is matched where it actually appears
      # (and a `shrink_to_fit` widget by its shrunk content box, not the full slot
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
      true
    end

    # Single self-or-ancestor pass returning `{displayed?, layer_key}` for a
    # hit-test candidate — folds what were two separate parent-chain walks
    # (whole-chain visibility, then outermost-`z_index` layer) into one, since
    # `#widget_at` runs this on every mouse report (all motion included).
    #
    # *displayed?* is false when the widget or ANY ancestor is hidden — its own
    # `#visible?` flag reflects only itself, so a "shown" widget inside a hidden
    # container (e.g. a non-current tab page) must not intercept clicks. When
    # false the layer key is meaningless (the candidate is discarded).
    #
    # *layer_key* is the compositing layer the candidate is painted into, as a
    # sortable `{plane?, z}`: `{0, 0}` is the base layer (no `z-index` on the
    # widget or an ancestor); a z-indexed subtree resolves to `{1, z}` — above
    # any base widget (leading `1` beats `0` even for negative `z`, matching
    # `composite_planes`) and ordered among planes by `z`. The OUTERMOST
    # self-or-ancestor `z_index` wins (each ancestor's value overwrites): painting
    # defers only the FIRST z-indexed widget met on the walk down (a nested
    # z-indexed subtree flattens into its enclosing plane — see
    # `compositing_layers?`), so a nested z must not let an occluded widget
    # out-rank the plane it is actually painted into.
    #
    # Returned as a value tuple (stack, no heap), keeping this path allocation-free.
    private def hit_visible_and_layer(el : Widget) : Tuple(Bool, Tuple(Int32, Int32))
      visible = true
      z = nil
      cur : Widget? = el
      while cur
        visible = false unless cur.style.visible?
        if zz = cur.style.z_index
          z = zz
        end
        cur = cur.parent
      end
      {visible, z ? {1, z} : {0, 0}}
    end

    # Whether *el* and every ancestor are visible — i.e. actually on screen, not
    # merely flagged visible while sitting in a hidden container.
    #
    # Forwards to `Widget#visible_in_tree?`, the one true predicate. The former
    # hand-rolled walk read `style.visible?` rather than `#visible?`'s
    # `state_style.visible?`; the two can never disagree on `visible` (the only
    # divergence is `#style`'s reverse-video `#dup` for a floor-highlighted
    # `:focused`/`:selected` widget, and a `dup` carries `visible` through
    # unchanged), so the answer is identical — and `state_style` skips the
    # resolution `#style` runs, which this per-event hit-test/focus path is on.
    private def displayed_in_tree?(el : Widget) : Bool
      el.visible_in_tree?
    end

    # Registers *el* as a widget that wants mouse input. Mirrors
    # `#register_keyable`; lazily ensures terminal mouse reporting is on if
    # mouse listening is already active (blessed-style on-demand enabling).
    def register_clickable(el : Widget)
      return unless register_in el, @clickable
      el.clickable = true
      @screen.enable_mouse(focus: send_focus?) if @screen.mouse_enabled?
    end
  end
end
