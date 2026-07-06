module Crysterm
  class Window
    # Drag-and-drop engine.
    #
    # A drag is modal and per-screen: at most one gesture is in flight at a time
    # (`@_drag`). The mouse sensor (`#dispatch_mouse`) and keyboard sensor
    # (`#_drag_key_handled`) drive the same session and emit the same
    # source/target events, so widgets need no per-input branching.

    # In-flight drag gesture, or `nil`.
    @_drag : DragSession? = nil

    # Armed (pending) drag: the pointer pressed over a draggable widget but has
    # not yet moved. Promoted to a real drag only once it moves, so a plain
    # click is unaffected.
    @_arm : Widget? = nil
    @_arm_x = 0
    @_arm_y = 0

    # Transient "ghost" widget floated under the pointer during a transfer drag.
    @_drag_ghost : Widget? = nil

    # Two-click mouse fallback for terminals that do not report motion: a press
    # on a draggable widget lifts it, the next press drops it. Off by default.
    property? drag_two_click : Bool = false

    # Whether to float a ghost label under the pointer during a (mouse) transfer
    # drag. On by default; ignored for reposition (the widget itself moves) and
    # for the keyboard sensor (no pointer to follow).
    property? drag_ghost : Bool = true

    # Optional sink for human-readable drag status (e.g. a status-line "live
    # region" for keyboard users: "Picked up …", "Over …", "Dropped on …",
    # "Cancelled"). No-op when unset.
    property drag_announce : Proc(String, Nil)? = nil

    # The in-flight drag session on this screen, if any.
    def dragging : DragSession?
      @_drag
    end

    # Begins a drag with *source* as the dragged widget. Shared by both sensors.
    # *x*/*y* are absolute cell coordinates of the anchor (the pointer for mouse;
    # the source's top-left for keyboard). *action* seeds the negotiation (from
    # modifier keys for mouse, per the desktop Ctrl→Copy / Shift→Move convention).
    def start_drag(source : Widget, x : Int32, y : Int32, sensor : DragSensor,
                   action : DragAction = DragAction::Move, discrete : Bool = false) : DragSession
      data = DragData.new source, [action], action
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
      sess.data.action = drag_action_for shift, ctrl, sess.data.supported.first? || DragAction::Move
      sess.x = x
      sess.y = y
      sess.source.emit ::Crysterm::Event::Drag, sess
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
      # reposition handler clamps `left`/`top` to the parent's bounds
      # (`widget_interaction.cr`), but `sess.x`/`sess.y` above accumulate freely.
      # Without this, once the widget is pinned at an edge each further arrow in
      # that direction pushes the virtual anchor past the edge, and the user must
      # first unwind that overshoot before the widget moves back — input looks
      # dead for N presses. At pickup the anchor equals `aleft + offset_x`
      # (`offset_x == @_drag_dx`, both `x - aleft`), so recomputing it from the
      # post-clamp `aleft` keeps anchor and widget in lockstep. (Mouse drags set
      # `sess.x = x` absolutely, so they were never affected.)
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
        t.emit ::Crysterm::Event::DragOver, sess
      end
    end

    # Re-evaluate the drop target: point the session at *t* and immediately
    # re-ask it to accept. `retarget` and `over` are always invoked as this pair
    # (every place that changes the target must re-ask the new one), so they are
    # kept together here.
    private def retarget_over(sess : DragSession, t : Widget?) : Nil
      retarget sess, t
      over sess
    end

    # Steps keyboard focus one widget (*forward* or back), retargets the drag's
    # drop candidate onto the newly-focused widget, and re-renders — the shared
    # body of the Tab/Shift-Tab keys and the transfer-source arrow navigation.
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
      remove_ghost
      dropped = false
      if (t = sess.target) && sess.data.accepted?
        t.emit ::Crysterm::Event::Drop, sess
        dropped = true
        announce "Dropped on #{describe t}"
      else
        # A target that received `DragEnter` but did not accept the drop must
        # still be told the drag left it, or it stays in its drag-entered
        # visual state forever. Every `DragEnter` is balanced by exactly one
        # `Drop` or `DragLeave` — as `retarget` (on target change) and
        # `drag_cancel` (on Escape) already guarantee; this rejection-on-release
        # path was the one gap.
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

    private def announce(msg : String) : Nil
      @drag_announce.try &.call msg
    end

    private def describe(w : Widget) : String
      n = w.name
      n && !n.empty? ? n : w.class.name.split("::").last
    end

    # --- Ghost ----------------------------------------------------------------

    private def make_ghost(sess : DragSession) : Nil
      label = sess.data["text/plain"]? || "⠿ drag"
      gx, gy = ghost_origin sess
      g = Widget::Box.new(
        parent: self,
        width: {label.size + 2, 6}.max,
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
    # screen's content origin (`aleft == screen.ileft + left`), while
    # `sess.x`/`sess.y` are absolute, so the screen's padding must be subtracted
    # here — same as `Widget#drag_origin` does for reposition. On an unpadded
    # screen `ileft`/`itop` are 0, so this is a no-op there.
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
    # `Screen` (`screen_osc.cr`); this surface delegates it (see `window.cr`).

    # Inbound interop: synthesize a drop of externally-provided *uris* (e.g. a
    # file dragged from the desktop file manager, delivered as pasted
    # `file://`/path text) onto *target*. Builds a `text/uri-list` payload and
    # runs the same enter/over/drop negotiation an internal drag would, so
    # accepting a drop needs no extra code path. Returns whether accepted.
    def drop_external(uris : Array(String), target : Widget? = focused) : Bool
      return false unless t = target
      src = t
      data = DragData.new src, [DragAction::Copy], DragAction::Copy
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

    # Keyboard sensor. Called first from the screen key handler; returns true if
    # it consumed the key.
    #
    #   * No drag in flight: **Space** on a focused `draggable?` widget lifts it.
    #   * Dragging: **Tab/Shift-Tab** move focus (retargeting the drop target),
    #     **arrow keys** nudge a reposition, **Space/Enter** drop, **Escape**
    #     cancels.
    def _drag_key_handled(e : ::Crysterm::Event::KeyPress) : Bool
      if sess = @_drag
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
        when ::Tput::Key::Escape
          drag_cancel sess
          e.accept
          return true
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
      elsif (w = focused) && w.draggable? && e.char == ' '
        start_drag w, w.aleft, w.atop, ::Crysterm::DragSensor::Keyboard
        e.accept
        true
      else
        false
      end
    end
  end
end
