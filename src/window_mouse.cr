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
    def add_popup_grab(w : Widget) : Nil
      @grabs << w unless @grabs.includes? w
    end

    # Removes *w*'s input grab.
    def remove_popup_grab(w : Widget) : Nil
      @grabs.delete w
    end

    # Whether any input grab is active.
    def popup_grab_active? : Bool
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

    # Last dispatched pointer position (surface coordinates), so a hover ended
    # without a live report (`#end_hover`, e.g. from `#disable_mouse`) can hand
    # the synthetic `MouseLeave` real coordinates.
    @_last_mouse_x = 0
    @_last_mouse_y = 0

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

      end_hover(notify: false) if drop_hover
      self.mouse_cursor_shape = nil if drop_hover
      @_arm = nil if drop_arm
      @_mouse_captor = nil if drop_captor
      stale_drag.try { |sd| drag_cancel sd if @_drag == sd }
      stale_target.try { |st| retarget(st, nil) if @_drag == st }
      stale_grabs.each { |g| remove_popup_grab g }
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

    # Ends the current hover (if any): drops `@_hover` and, when *notify* is
    # true, emits a synthetic `Event::MouseLeave` on the widget, at the last
    # known pointer position. The hover-teardown sites share this so they can't
    # diverge: `#disable_mouse` notifies (the widget stays alive on-screen, so
    # its visible hover state — tooltip, highlight — must be told to revert),
    # while `#release_transient_state_for` doesn't (the widget is being
    # removed; firing events on a dead widget is the hazard it exists to
    # prevent).
    private def end_hover(*, notify : Bool) : Nil
      return unless old = @_hover
      @_hover = nil
      return unless notify
      ev = ::Tput::Mouse::Event.new(
        ::Tput::Mouse::Action::Move, ::Tput::Mouse::Button::None,
        @_last_mouse_x, @_last_mouse_y, source: :program)
      old.emit ::Crysterm::Event::MouseLeave, mouse_out_event(ev, old)
    end

    # Turns off mouse reporting on the device and ends this surface's hover —
    # `Screen#disable_mouse` handles terminal/gpm/cursor teardown; the hover
    # end is the surface's half. Since no further report can ever deliver the
    # leave once reporting is off, it is synthesized here (before the device
    # teardown, so leave handlers' terminal writes still land) — otherwise a
    # hovered widget's visible state (tooltip, hover highlight, status-bar
    # hint) would stay stale indefinitely.
    def disable_mouse : Nil
      end_hover notify: true
      @screen.disable_mouse
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
    #
    # Deliberately one flat dispatcher over every mouse action kind; splitting
    # it to satisfy the metric would scatter the event-routing rules.
    # Synthesizes a full mouse click — button press then release — at cell
    # (*x*, *y*), routed through `#dispatch_mouse` like a real report, so
    # hit-testing, focus-on-click, hover and `Event::Click` all apply:
    # `window.click 2, 0`. For tests, demos and self-driving programs.
    def click(x : Int32, y : Int32, button : ::Tput::Mouse::Button = ::Tput::Mouse::Button::Left) : Nil
      dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Down, button, x, y)
      dispatch_mouse ::Tput::Mouse::Event.new(::Tput::Mouse::Action::Up, button, x, y)
    end

    # Synthesizes a wheel scroll at cell (*x*, *y*): `window.wheel :up, 40, 10`.
    # *direction* is `:up` or `:down` — deliberately not a
    # `Tput::Mouse::Action`, whose `Down`/`Up` members mean button transitions.
    def wheel(direction : Symbol, x : Int32, y : Int32) : Nil
      action = case direction
               when :up   then ::Tput::Mouse::Action::WheelUp
               when :down then ::Tput::Mouse::Action::WheelDown
               else            raise ArgumentError.new("wheel direction must be :up or :down, got #{direction.inspect}")
               end
      dispatch_mouse ::Tput::Mouse::Event.new(action, ::Tput::Mouse::Button::None, x, y)
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def dispatch_mouse(ev : ::Tput::Mouse::Event)
      ev = translate_inline_mouse ev

      emit ::Crysterm::Event::Mouse, mouse_event(ev)

      # Focus in/out reports (mode 1004) share this channel but carry no
      # pointer position; surface on the screen and stop before hit-testing.
      return if ev.focus_event?

      # Every remaining report carries a real position: remember it, so a hover
      # ended without a report (`#end_hover`) has coordinates to synthesize from.
      @_last_mouse_x = ev.x
      @_last_mouse_y = ev.y

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
      me = w.emit ::Crysterm::Event::Mouse, mouse_event(ev, w)
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
      elsif d = wheel_delta(ev)
        scroll_under w, d, horizontal: ev.shift?
      end
    end

    # The scroll delta a wheel report carries — `-1` for a wheel-up, `1` for a
    # wheel-down — or `nil` when *ev* is not a wheel report at all. The single
    # spelling of both the "is this a wheel?" test and the direction→delta
    # mapping, shared by every member of the wheel-dispatch family
    # (`#dispatch_mouse`, `#wheel_focuses`, `#handle_disabled_wheel`) so they
    # cannot disagree on either.
    @[AlwaysInline]
    private def wheel_delta(ev : ::Tput::Mouse::Event) : Int32?
      if ev.action.wheel_up?
        -1
      elsif ev.action.wheel_down?
        1
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
      return unless wheel_delta(ev)
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
      return false unless w.disabled? && (d = wheel_delta(ev))
      w.parent.try { |p| scroll_under p, d, horizontal: ev.shift? }
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
        captor.emit ::Crysterm::Event::Mouse, mouse_event(ev, captor)
        return true
      elsif ev.action.up?
        captor.emit ::Crysterm::Event::Mouse, mouse_event(ev, captor)
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

    # The nearest widget at or above *w* whose focus policy grants wheel focus
    # (see `Widget#accepts_wheel_focus?` — Qt's `Wheel` rule with an explicit
    # policy, the historical any-click-focusable behavior without), or `nil`.
    private def focusable_at(w : Widget) : Widget?
      # Skip disabled widgets (not a focus target), matching Tab navigation.
      w.first_self_or_ancestor { |el| el.accepts_wheel_focus? && !el.disabled? }
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
          old.emit ::Crysterm::Event::MouseLeave, mouse_out_event(ev, old)
        end
        @_hover = w
        if w
          w.emit ::Crysterm::Event::MouseEnter, mouse_over_event(ev, w)
        end
      elsif w && ev.action.move?
        w.emit ::Crysterm::Event::MouseMove, mouse_move_event(ev, w)
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
      # Hover memo. A pointer crossing the screen produces far more reports than
      # distinct cells — SGR-Pixels (DEC 1016) emits one per sub-cell step with
      # `x`/`y` unchanged, terminals repeat same-cell reports, and a resting
      # pointer repeats indefinitely — while the answer for a given cell can only
      # change when the frame does: the geometry `#hit_candidate?` tests is
      # `lpos`, which only a render lays down. So the frame counter carries the
      # invalidation, and a repeat within one frame skips the walk entirely. The
      # candidate test's other half, `wants_mouse?`, is not render-derived, so
      # `#register_clickable` drops the memo by hand.
      #
      # Only the plain hover/click lookup is memoized. A `skip:` lookup (the drag
      # path) asks a different question at the same coordinates, and a drag ghost
      # is a per-report exclusion, so neither reads the memo nor writes it.
      memoizable = skip.nil? && @_drag_ghost.nil?
      if memoizable && @_hit_memo_renders == renders && @_hit_memo_x == x && @_hit_memo_y == y
        return @_hit_memo
      end
      @hit_scans += 1
      # Traverse without a captured `Proc`: an `each_descendant` block would
      # reify a heap closure on every call — i.e. every mouse report, motion
      # included. The scan accumulates the best hit in scratch ivars instead;
      # dispatch is single-fiber synchronous, so reusing them is safe.
      @_hit_found = nil
      @_hit_found_key = {0, 0}
      # Seed the walk with "visible so far, no ancestor z-index" — the answer a
      # parentless top-level widget's ancestor chain yields.
      children.each do |el|
        hit_scan el, x, y, skip, true, nil
      end
      if memoizable
        @_hit_memo = @_hit_found
        @_hit_memo_x = x
        @_hit_memo_y = y
        @_hit_memo_renders = renders
      end
      @_hit_found
    end

    # Number of full hit-test walks `#widget_at` has run, i.e. the calls that did
    # NOT come back from the hover memo. Instrumentation: specs and benchmarks
    # assert on the memo without having to observe it directly.
    getter hit_scans = 0_u64

    # The hover memo: the last answer, the cell it answers for, and the frame it
    # was taken in. `@_hit_memo_renders` starts at -1 so it can never match
    # `renders` (0 before the first frame) by accident.
    @_hit_memo : Widget?
    @_hit_memo_x = Int32::MIN
    @_hit_memo_y = Int32::MIN
    @_hit_memo_renders = -1

    # Scratch state for `#widget_at`'s allocation-free traversal: the best hit
    # so far and its compositing layer key. Only valid for the duration of one
    # synchronous `widget_at` call.
    @_hit_found : Widget?
    @_hit_found_key : Tuple(Int32, Int32) = {0, 0}

    # Pre-order depth-first walk (visit *el*, then recurse into its children in
    # `@children` order), scoring each widget as a hit-test candidate into
    # `@_hit_found`/`@_hit_found_key`. A widget that fails the candidate test
    # still has its subtree scanned; a widget that is not *visible* does not,
    # see below.
    #
    # Whole-chain visibility and the outermost-`z_index` layer key are threaded
    # DOWN the recursion (*anc_visible*, *anc_z* carry the parent's accumulated
    # answer) instead of re-walking the parent chain per candidate: each node
    # folds itself in with one `&&`/`||` — O(1) per node rather than
    # O(candidates x depth). `anc_visible` ANDs `style.visible?`
    # (order-independent); `anc_z || el.style.z_index` keeps the OUTERMOST
    # (root-most) z, since a set `anc_z` — including a genuine `0` — wins over a
    # deeper one.
    #
    # An invisible node ends the walk of its subtree, and this prune is EXACT,
    # not a heuristic: unlike z-index — which deliberately escapes a subtree by
    # promoting it to a higher layer — visibility is a pure AND with no escape
    # hatch, so once it is false no descendant can turn it back on and none can
    # pass the candidate gate. Nothing else is skipped: `#hit_candidate?` only
    # reads `lpos`/`wants_mouse?`, so an unvisited node had no side effect to
    # contribute. Worth doing because hidden subtrees are routine and large
    # (non-current `TabWidget`/`StackedWidget`/`ToolBox` pages, closed
    # `Menu`/`ComboBox` popups, hidden dialogs) while `#widget_at` runs on every
    # mouse report, motion included.
    #
    # A *clipping* container (`scrollable?` or `overflow: Hidden` — the exact
    # predicate `Widget#clip_ancestor` matches) prunes the same way when the
    # point falls outside its painted rect: `coords` clips every descendant's
    # `lpos` to its clipping ancestor's viewport (a nested clipper's own `lpos`
    # is clipped in turn, so the containment is transitive), hence no descendant
    # can paint — or be hit — outside it. Only two things escape that clip, and
    # both are handled rather than assumed away:
    #
    # * `z_index` does NOT escape it. A layered subtree composites onto a `Plane`
    #   painted above the base layer, but its geometry still runs through
    #   `coords`, which clips against `#clip_ancestor` unconditionally: a
    #   z-indexed child scrolled out of its container gets `lpos == nil` exactly
    #   like a plain one, so it paints nothing and is no candidate either way.
    #   The layer key only reorders candidates *within* the scan; it never
    #   revives a clipped-away one.
    # * `fixed` DOES escape it, and only it: `#clip_ancestor` lets a `fixed`
    #   widget (border labels, bound scroll bars, background layers) skip exactly
    #   one *scrollable* clipper, so such a descendant is clipped by the NEXT
    #   clipper up and can legitimately paint outside this one. So a scrollable
    #   clipper hands its subtree to `#hit_scan_escapee` instead of dropping it,
    #   while a non-scrollable `overflow: Hidden` one — which `#clip_ancestor`
    #   never skips, `fixed` or not — is pruned outright.
    private def hit_scan(el : Widget, x : Int32, y : Int32, skip : Widget?, anc_visible : Bool, anc_z : Int32?) : Nil
      visible = anc_visible && el.style.visible?
      return unless visible
      z = anc_z || el.style.z_index
      if hit_candidate?(el, x, y, skip)
        key = z ? {1, z} : {0, 0}
        # Prefer a higher layer; within the same layer `>=` keeps "last wins"
        # (the common no-z-index case, where every key is `{0, 0}`).
        if @_hit_found.nil? || key >= @_hit_found_key
          @_hit_found = el
          @_hit_found_key = key
        end
      end

      # Leaf fast path, taken by most of the tree: nothing to prune, so skip the
      # clip test entirely rather than paying it per widget in a flat UI.
      kids = el.children
      return if kids.empty?

      # The clip prune. Guarded on a present `lpos`: a clipper that painted
      # nothing has no viewport to test against (pre-first-render, or itself
      # clipped away), so the walk proceeds as before.
      if (lp = el.lpos) && !lp.contains?(x, y) && clips_children?(el)
        return unless el.scrollable?
        kids.each do |c|
          hit_scan_escapee c, x, y, skip, el, visible, z
        end
        return
      end

      kids.each do |c|
        hit_scan c, x, y, skip, visible, z
      end
    end

    # Reduced walk over the subtree of a *scrollable* clipper the point falls
    # outside of, hunting only for the `fixed` descendants that `#clip_ancestor`
    # exempts from that clipper (see `#hit_scan`). Nothing else in there can be a
    # candidate, so nothing here scores, resolves a `Style` or touches `lpos`:
    # the hunt reads three plain ivars per node and recurses. That matters — it
    # runs over the whole subtree the prune would otherwise have dropped, and a
    # per-node `style` lookup alone costs about as much as the full scan it is
    # replacing, which would leave the prune barely worth its keep.
    #
    # The chain state a resumed full scan needs (*anc_visible*/*anc_z* folded
    # from *clipper* down) is therefore NOT threaded here; it is reconstructed by
    # `#escapee_ancestry` at the rare node that actually escapes.
    #
    # The hunt stops at every intervening clipper, which is exact rather than
    # merely cheap: a `fixed` descendant *below* such a clipper spends its one
    # exemption on it and is then clipped by *clipper*, which we already know
    # excludes the point; a non-`fixed` one is clipped by the intervening clipper,
    # whose own rect is inside *clipper*'s. Either way nothing under it is
    # hittable. Invisible subtrees are not pruned here (that would cost the very
    # `style` lookup this walk avoids) — they are simply rarer than the nodes
    # paying for the check, and `#hit_scan` still folds visibility at the escapee.
    private def hit_scan_escapee(el : Widget, x : Int32, y : Int32, skip : Widget?, clipper : Widget, anc_visible : Bool, anc_z : Int32?) : Nil
      if el.fixed?
        # Exempt from the clip that pruned us: back to the full scan, which
        # re-tests the widget's real (still clipped-to-ITS-ancestor) `lpos`.
        visible, z = escapee_ancestry el, clipper, anc_visible, anc_z
        hit_scan el, x, y, skip, visible, z if visible
        return
      end
      return if clips_children? el
      el.children.each do |c|
        hit_scan_escapee c, x, y, skip, clipper, anc_visible, anc_z
      end
    end

    # Folds whole-chain visibility and the outermost `z_index` over the widgets
    # strictly between *clipper* and *el*, on top of the state *clipper* itself
    # already accumulated — the same answer `#hit_scan` would have threaded down,
    # recomputed on demand for the one node in a pruned subtree that needs it
    # (see `#hit_scan_escapee`). Climbing yields the outermost `z_index` because
    # each ancestor found overwrites the deeper one, and *anc_z* — already the
    # root-most — still wins over all of them.
    private def escapee_ancestry(el : Widget, clipper : Widget, anc_visible : Bool, anc_z : Int32?) : Tuple(Bool, Int32?)
      visible = anc_visible
      z : Int32? = nil
      n = el.parent
      while n && !n.same?(clipper)
        st = n.style
        visible &&= st.visible?
        if zi = st.z_index
          z = zi
        end
        n = n.parent
      end
      {visible, anc_z || z}
    end

    # Whether *el* clips its children's rendering to its own rect, i.e. whether
    # `Widget#clip_ancestor` would stop at it. Only reached for a widget that has
    # children and does not contain the point, never for the leaves that make up
    # most of a tree.
    #
    # `el.overflow` is inlined as "own override, else the window default"
    # because that is precisely what it computes — and everything this walk
    # reaches is a descendant of `self`, so the `window?` lookup and `try` it
    # would spend per node to find that default can only ever answer `self`.
    private def clips_children?(el : Widget) : Bool
      return true if el.scrollable?
      (o = el.own_overflow) ? o.hidden? : overflow.hidden?
    end

    # Whether *el* itself is a hit-test candidate occupying (*x*, *y*) — the
    # per-widget body of the `widget_at` scan; a failing check `return false`s
    # rather than `next`s. Runs the two cheap self-only checks in order (`lpos`
    # first, then `wants_mouse?`); whole-chain visibility is threaded down the
    # `#hit_scan` walk (not resolved here), so a passing candidate is only tested
    # once its accumulated ancestor visibility already holds.
    private def hit_candidate?(el : Widget, x : Int32, y : Int32, skip : Widget?) : Bool
      return false if skip && el == skip
      # The transient drag ghost is decorative, never a drop target.
      return false if (g = @_drag_ghost) && el == g

      # Cheapest check first: hit-test against the widget's *painted* rectangle
      # (`lpos`), not the raw `aleft/atop/awidth/aheight` geometry. `lpos` is
      # what `base_render` laid down: it folds in the margin shift AND the
      # enclosing-scroll offset (`base`) and clips to every clipping ancestor's
      # viewport, so a scrolled list item is matched where it actually appears
      # (and a `shrink_to_fit` widget by its shrunk content box, not the full slot
      # `awidth` reports). Raw geometry would ignore all of that and hit-test
      # scrolled/shrunk children by their unscrolled, unclipped rectangle.
      # `render_children` refreshes every descendant's `lpos` each frame, so it
      # is current once the window has painted.
      lp = el.lpos
      if lp
        return false unless lp.contains? x, y
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

    # (The whole-chain visibility + outermost-`z_index` layer key that a hit-test
    # candidate needs are threaded down `#hit_scan` — see its doc for the
    # layer-key semantics: `{0, 0}` base layer, `{1, z}` for a z-indexed subtree
    # where the OUTERMOST self-or-ancestor `z_index` wins.)

    # Registers *el* as a widget that wants mouse input. Mirrors
    # `#register_keyable`; lazily ensures terminal mouse reporting is on if
    # mouse listening is already active (blessed-style on-demand enabling).
    def register_clickable(el : Widget)
      return unless register_in el, @clickable
      # A new candidate can change the answer under a pointer that has not moved,
      # and no render need intervene — the one hover-memo input the frame counter
      # does not cover (see `#widget_at`).
      @_hit_memo_renders = -1
      el.clickable = true
      @screen.enable_mouse(focus: send_focus?) if @screen.mouse_enabled?
    end
  end
end
