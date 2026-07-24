module Crysterm
  class Window
    # Drag-and-drop engine.
    #
    # A drag is modal and per-screen: at most one gesture is in flight at a time.
    # The mouse and keyboard sensors drive the same session and emit the same
    # source/target events, so widgets need no per-input branching.

    # In-flight drag gesture, or `nil`.
    @_drag : DragSession? = nil

    # Armed (pending) drag: the pointer pressed over a draggable widget but has
    # not yet moved. Promoted to a real drag only once it moves, so a plain
    # click is unaffected.
    @_arm : Widget? = nil
    @_arm_x = 0
    @_arm_y = 0

    # Button of the arming press, carried onto `@_drag_button` when the arm is
    # promoted to a drag.
    @_arm_button : ::Tput::Mouse::Button? = nil

    # Button that initiated the in-flight mouse drag: only its release commits
    # the Drop — a stray other-button tap mid-gesture must not commit at the
    # pointer. `nil` for keyboard drags.
    @_drag_button : ::Tput::Mouse::Button? = nil

    # Transient "ghost" widget floated under the pointer during a transfer drag.
    @_drag_ghost : Widget? = nil

    # Per-Window pooled drag events, reused across the per-motion `Drag`/
    # `DragOver` emits so streamed motion doesn't heap-allocate a fresh event
    # each report (as pooled mouse events do for mouse reports). The
    # once-per-gesture emits (DragStart/End/Drop/Enter/Leave) stay unpooled.
    # See `Event::DragEvent#reset` for the retention caveat.
    @_drag_event : ::Crysterm::Event::Drag? = nil
    @_drag_over_event : ::Crysterm::Event::DragOver? = nil

    private def pooled_drag_event(sess : DragSession) : ::Crysterm::Event::Drag
      (@_drag_event ||= ::Crysterm::Event::Drag.new(sess)).reset sess
    end

    private def pooled_drag_over_event(sess : DragSession) : ::Crysterm::Event::DragOver
      (@_drag_over_event ||= ::Crysterm::Event::DragOver.new(sess)).reset sess
    end

    # Two-click mouse fallback for terminals that do not report motion: a press
    # on a draggable widget lifts it, the next press drops it. Off by default.
    property? drag_two_click : Bool = false

    # Whether to float a ghost label under the pointer during a (mouse) transfer
    # drag. On by default; ignored for reposition (the widget itself moves) and
    # for the keyboard sensor (no pointer to follow).
    property? drag_ghost : Bool = true

    # The in-flight drag session on this screen, if any.
    def drag_session : DragSession?
      @_drag
    end

    # Whether a drag is currently in flight on this screen.
    def dragging? : Bool
      !@_drag.nil?
    end

    # Begins a drag with *source* as the dragged widget. *x*/*y* are absolute
    # cell coordinates of the anchor (the pointer for mouse; the source's
    # top-left for keyboard). *action* seeds the negotiation (from modifier keys
    # for mouse, per the desktop Ctrl→Copy / Shift→Move convention).
    def start_drag(source : Widget, x : Int32, y : Int32, sensor : DragSensor,
                   action : DragAction = DragAction::Move, discrete : Bool = false) : DragSession
      # A new gesture must never silently replace a live one (e.g. a mouse press
      # promoting to a drag while a keyboard-sensor drag is in flight): the old
      # source would never get `DragEnd` and its target never `DragLeave`,
      # breaking the "every DragEnter balanced by one Drop/DragLeave" invariant.
      #
      # `drag_cancel` nils `@_drag_button`, but the mouse callers set it BEFORE
      # calling `start_drag` (the arming button of the NEW drag). Snapshot and
      # restore it, or cancelling the old session erases the new drag's button —
      # and a nil button makes any release/press commit the drop.
      if old = @_drag
        saved_button = @_drag_button
        drag_cancel old
        @_drag_button = saved_button
      end
      data = DragData.new source, action, action
      sess = DragSession.new source, data, x, y, sensor
      sess.discrete = discrete || sensor.keyboard?
      sess.offset_x = x - source.aleft
      sess.offset_y = y - source.atop
      @_drag = sess

      source.emit ::Crysterm::Event::DragStart, sess

      # A transfer source (doesn't self-move) gets a floating ghost.
      if drag_ghost? && sensor.mouse? && !source.drag_repositions?
        make_ghost sess
      end

      announce "Picked up #{describe source}"

      # Establish the initial drop target.
      if sensor.mouse?
        retarget_over sess, widget_at(x, y, skip: source)
      else
        # Keyboard: target follows focus, starting on the source itself.
        retarget_over sess, focused
      end
      render
      sess
    end

    # Mouse motion during a drag: update the negotiated action from the live
    # modifier keys, move the anchor, let the source react (`Drag` → e.g.
    # reposition), float the ghost, then re-evaluate and re-ask the drop target.
    def drag_motion(sess : DragSession, x : Int32, y : Int32, shift = false, ctrl = false) : Nil
      sess.data.action = drag_action_for shift, ctrl, default_supported_action(sess.data.supported)
      sess.x = x
      sess.y = y
      sess.source.emit ::Crysterm::Event::Drag, pooled_drag_event(sess)
      move_ghost sess
      retarget_over sess, widget_at(x, y, skip: sess.source)
      render
    end

    # Keyboard arrow during a drag. A repositioning source moves in the pressed
    # direction (`drag_nudge`). A transfer source has nothing to reposition, so
    # arrows retarget the drop candidate instead — mirroring Tab/Shift-Tab:
    # right/down step to the next focusable, left/up to the previous.
    private def drag_arrow(sess : DragSession, dx : Int32, dy : Int32) : Nil
      if sess.source.drag_repositions?
        drag_nudge sess, dx, dy
      else
        drag_focus_step sess, (dx > 0 || dy > 0)
      end
    end

    # Keyboard nudge during a reposition drag: shift the anchor by (*dx*, *dy*)
    # cells and let the source reposition through its `Drag` handler.
    def drag_nudge(sess : DragSession, dx : Int32, dy : Int32) : Nil
      sess.x += dx
      sess.y += dy
      src = sess.source
      src.emit ::Crysterm::Event::Drag, sess
      # Re-sync the anchor to the source's ACTUAL (clamped) position. The
      # reposition handler clamps `left`/`top` to the parent's bounds, but
      # `sess.x`/`sess.y` above accumulate freely: without this, once the widget
      # is pinned at an edge each further arrow pushes the virtual anchor past
      # it, and the user must unwind that overshoot before the widget moves back
      # — input looks dead for N presses. At pickup the anchor equals
      # `aleft + offset_x`, so recomputing it from the post-clamp `aleft` keeps
      # anchor and widget in lockstep. Mouse drags set `sess.x` absolutely and
      # are unaffected.
      sess.x = src.aleft + sess.offset_x
      sess.y = src.atop + sess.offset_y
      render
    end

    # Switches the candidate drop target, emitting `DragLeave`/`DragEnter`.
    private def retarget(sess : DragSession, t : Widget?) : Nil
      old = sess.target
      return if t == old
      old.try &.emit ::Crysterm::Event::DragLeave, sess
      sess.target = t
      if t
        t.emit ::Crysterm::Event::DragEnter, sess
        announce "Over #{describe t}"
      end
    end

    # Emits `DragOver` on the current target, re-asking it to accept. Acceptance
    # is withdrawn first so the answer can change as modifier keys change.
    private def over(sess : DragSession) : Nil
      if t = sess.target
        sess.data.reject
        t.emit ::Crysterm::Event::DragOver, pooled_drag_over_event(sess)
      end
    end

    # Re-evaluate the drop target: point the session at *t* and immediately
    # re-ask it to accept. Every place that changes the target must re-ask the
    # new one, so the two always go together.
    private def retarget_over(sess : DragSession, t : Widget?) : Nil
      retarget sess, t
      over sess
    end

    # Steps keyboard focus one widget (*forward* or back), retargets the drag's
    # drop candidate onto the newly-focused widget, and re-renders.
    private def drag_focus_step(sess : DragSession, forward : Bool) : Nil
      forward ? focus_next : focus_previous
      retarget_over sess, focused
      render
    end

    # Commits the drag at the current target. An accepting target receives a
    # `Drop`; the source always receives a `DragEnd` reporting success so a Move
    # source can remove the original (a Copy source keeps it).
    def drag_release(sess : DragSession) : Nil
      @_drag = nil
      @_drag_button = nil
      remove_ghost
      dropped = false
      if (t = sess.target) && sess.data.accepted?
        t.emit ::Crysterm::Event::Drop, sess
        dropped = true
        announce "Dropped on #{describe t}"
      else
        # A target that received `DragEnter` but did not accept the drop must
        # still be told the drag left it, or it stays in its drag-entered visual
        # state forever: every `DragEnter` is balanced by exactly one `Drop` or
        # `DragLeave`.
        sess.target.try &.emit ::Crysterm::Event::DragLeave, sess
        announce "Dropped"
      end
      ev = ::Crysterm::Event::DragEnd.new sess
      ev.dropped = dropped
      sess.source.emit ev
      render
    end

    # Cancels the drag (e.g. Escape) without dropping.
    def drag_cancel(sess : DragSession) : Nil
      @_drag = nil
      @_drag_button = nil
      remove_ghost
      sess.target.try &.emit ::Crysterm::Event::DragLeave, sess
      ev = ::Crysterm::Event::DragEnd.new sess
      ev.dropped = false
      sess.source.emit ev
      announce "Cancelled"
      render
    end

    # Ctrl forces Copy, Shift forces Move — the cross-platform desktop
    # convention. Otherwise the proposed *default* stands.
    private def drag_action_for(shift : Bool, ctrl : Bool, default : DragAction) : DragAction
      return DragAction::Copy if ctrl
      return DragAction::Move if shift
      default
    end

    # A single default action to propose absent modifier keys, from a
    # (possibly multi-flag) `DragData#supported` set: `Move` if advertised,
    # else `Copy`, else `Link`, else `Move` as the final fallback (`None`
    # advertises nothing, which shouldn't happen in practice).
    private def default_supported_action(supported : DragAction) : DragAction
      return DragAction::Move if supported.move? || supported.none?
      return DragAction::Copy if supported.copy?
      return DragAction::Link if supported.link?
      DragAction::Move
    end

    private def announce(msg : String) : Nil
      emit ::Crysterm::Event::DragAnnounced, msg
    end

    private def describe(w : Widget) : String
      n = w.name
      n && !n.empty? ? n : w.class.name.split("::").last
    end

    # --- Ghost ----------------------------------------------------------------

    private def make_ghost(sess : DragSession) : Nil
      label = sess.data["text/plain"]? || "#{Glyphs[Glyphs::Role::DragHandle, glyph_tier]} drag"
      gx, gy = ghost_origin sess
      g = Widget::Box.new(
        parent: self,
        # Size by terminal COLUMNS, not codepoints: a CJK/emoji label needs ~2
        # columns per glyph, so `label.size` would halve the ghost's width and
        # clip the label mid-glyph. (`Unicode.width` measures a single grapheme
        # cluster; `display_width` sums the string.)
        width: {::Crysterm::Unicode.display_width(label) + 2, 6}.max,
        height: 1,
        left: gx,
        top: gy,
        content: label,
        # Reverse-video so the ghost reads on any theme without a hardcoded color.
        style: Style.new(reverse: true))
      @_drag_ghost = g
    end

    private def move_ghost(sess : DragSession) : Nil
      g = @_drag_ghost
      return unless g
      gx, gy = ghost_origin sess
      g.left = gx
      g.top = gy
    end

    # Ghost `left`/`top` so it floats at absolute cell (`sess.x + 1`, `sess.y`),
    # under the pointer. A top-level widget's `left`/`top` are relative to the
    # screen's content origin (`aleft == screen.ileft + left`) while
    # `sess.x`/`sess.y` are absolute, so the screen's padding must be subtracted
    # here. A no-op on an unpadded screen, where `ileft`/`itop` are 0.
    private def ghost_origin(sess : DragSession) : Tuple(Int32, Int32)
      {sess.x + 1 - ileft, sess.y - itop}
    end

    private def remove_ghost : Nil
      if g = @_drag_ghost
        remove g
        @_drag_ghost = nil
      end
    end

    # --- Desktop-edge bridges -------------------------------------------------

    # Outbound interop (`#copy_to_clipboard`, OSC-52 clipboard write) lives on
    # `Screen`; this surface delegates it.

    # Inbound interop: synthesize a drop of externally-provided *uris* (e.g. a
    # file dragged from the desktop file manager, delivered as pasted
    # `file://`/path text) onto *target*. Builds a `text/uri-list` payload and
    # runs the same enter/over/drop negotiation an internal drag would, so
    # accepting a drop needs no extra code path. Returns whether accepted.
    def drop_external(uris : Array(String), target : Widget? = focused) : Bool
      return false unless t = target
      src = t
      data = DragData.new src, DragAction::Copy, DragAction::Copy
      data["text/uri-list"] = uris.join '\n'
      data["text/plain"] = uris.join '\n'
      sess = DragSession.new src, data, t.aleft, t.atop, DragSensor::Mouse
      sess.target = t
      t.emit ::Crysterm::Event::DragEnter, sess
      data.reject
      t.emit ::Crysterm::Event::DragOver, sess
      dropped = false
      if data.accepted?
        t.emit ::Crysterm::Event::Drop, sess
        dropped = true
      else
        t.emit ::Crysterm::Event::DragLeave, sess
      end
      render
      dropped
    end

    # Keyboard sensor; returns true if it consumed the key.
    #
    #   * No drag in flight: **Space** on a focused `draggable?` widget lifts it.
    #   * Dragging: **Tab/Shift-Tab** move focus (retargeting the drop target),
    #     **arrow keys** nudge a reposition, **Space/Enter** drop, **Escape**
    #     cancels.
    def _drag_key_handled(e : ::Crysterm::Event::KeyPress) : Bool
      if sess = @_drag
        # Escape cancels a drag from EITHER sensor — checked before the
        # keyboard-only early-return below, which would leave a mouse drag with
        # no cancel path at all.
        if e.key == ::Tput::Key::Escape
          drag_cancel sess
          e.accept
          return true
        end
        return false unless sess.sensor.keyboard?
        # Space is a printable char, delivered as `char == ' '` with `key == nil`
        # (unlike Enter/Tab/arrows). Match it by char.
        if e.char == ' ' || e.key == ::Tput::Key::Enter
          retarget_over sess, focused
          drag_release sess
          e.accept
          return true
        end
        case e.key
        when ::Tput::Key::Tab
          drag_focus_step sess, true
          e.accept
          return true
        when ::Tput::Key::ShiftTab
          drag_focus_step sess, false
          e.accept
          return true
        when ::Tput::Key::Up
          drag_arrow sess, 0, -1; e.accept; return true
        when ::Tput::Key::Down
          drag_arrow sess, 0, 1; e.accept; return true
        when ::Tput::Key::Left
          drag_arrow sess, -1, 0; e.accept; return true
        when ::Tput::Key::Right
          drag_arrow sess, 1, 0; e.accept; return true
        end
        false
      elsif (w = focused) && w.draggable? && !w.disabled? && e.char == ' '
        # A disabled widget can be focused (disabling doesn't rewind focus), but
        # must not be draggable — matching the mouse sensor's arm gate.
        start_drag w, w.aleft, w.atop, ::Crysterm::DragSensor::Keyboard
        e.accept
        true
      else
        false
      end
    end
  end
end
