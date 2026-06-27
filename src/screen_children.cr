module Crysterm
  class Screen
    def insert(element, i = -1)
      # Prevents adding an element twice
      super || return

      # A top-level widget (added straight to a Screen) is the single element
      # that actually stores its screen; its descendants derive it from the
      # tree. `previous` lets `attach` emit a `Detach` if it is being moved here
      # from another screen.
      previous = element.screen?
      element.screen = self
      attach element, previous

      # XXX:
      # - Make sure this is undo-ed if widget is detached
      if element.input? || element.keyable?
        register_keyable element
      end

      if element.clickable?
        register_clickable element
      end

      unless self.focused
        # element.focus
        focus_next
      end
    end

    # :ditto:
    def <<(element)
      insert element
    end

    def remove(element)
      return if element.screen? != self

      # Whether keyboard focus currently lives inside the subtree being removed.
      # This MUST be sampled *before* the unlink below: once `element.screen = nil`
      # severs the tree, a focused *descendant* (not `element` itself) can no longer
      # be related back to `element` via `has_descendant?`, and the check would
      # silently miss it — stranding focus on a now-detached, off-screen widget.
      refocus = (f = focused) && (f == element || element.has_descendant?(f))

      # Transient mouse-interaction pointers into the subtree being removed go
      # stale exactly as keyboard focus does, so they must be dropped too —
      # otherwise `screen.hovered` keeps reporting a detached widget (and the next
      # pointer move emits `MouseOut` on it), a *pending* (armed-but-not-yet-moved)
      # press later calls `start_drag` on a now-detached source, and an in-flight
      # drag whose source is removed stays modal forever (every subsequent mouse
      # event is swallowed by the `@_drag` branch of `#dispatch_mouse`). Sampled
      # here, before the unlink, for the same `has_descendant?` reason as `refocus`.
      drop_hover = (h = @_hover) && (h == element || element.has_descendant?(h))
      drop_arm = (a = @_arm) && (a == element || element.has_descendant?(a))
      stale_drag = ((d = @_drag) && (d.source == element || element.has_descendant?(d.source))) ? d : nil
      # An in-flight drag whose drop TARGET (not its source) sits in the removed
      # subtree would keep `@_drag.target` pointing at a now-detached widget — a
      # later drop (a keyboard Space/Enter, or a mouse release with no intervening
      # retarget) would then emit `Event::Drop` on an off-screen widget, since a
      # mouse drag otherwise only re-evaluates its target on motion. Sampled here,
      # before the unlink, for the same `has_descendant?` reason as the others;
      # cleared below by retargeting the drag to "no target".
      stale_target = ((td = @_drag) && (tg = td.target) && (tg == element || element.has_descendant?(tg))) ? td : nil
      # An active input grab (an open modal pop-up — menu, combo drop-down, … —
      # see `Screen#grab`) whose widget sits in the removed subtree must be
      # released. A pop-up normally `ungrab`s itself from its own close path, but
      # a direct `remove` bypasses that, leaving `@grabs` pointing at a detached
      # widget: every subsequent mouse event then runs `within_grab?` ->
      # `grab_contains?` on the off-screen widget, modally blocking interaction
      # with the rest of the screen forever (and dropping all hover/click). Sampled
      # before the unlink for the same `has_descendant?` reason as the others.
      stale_grabs = @grabs.select { |g| g == element || element.has_descendant?(g) }

      super

      # TODO Enable
      # if i = @display.clickable.index(element)
      #  @display.clickable.delete_at i
      # end
      # if i = @display.keyable.index(element)
      #  @display.keyable.delete_at i
      # end

      # s= @display
      # raise Exception.new() unless s
      # screen_clickable= s.clickable
      # screen_keyable= s.keyable

      # Clear the stored reference on this (top-level) element, then notify the
      # subtree that it has left this screen.
      previous = element.screen?
      element.screen = nil
      detach element, previous

      rewind_focus if refocus

      # Drop the stale mouse pointers sampled above. The drag is torn down via
      # `#drag_cancel` (not just nilled) so its `DragEnd`/`DragLeave` cleanup still
      # runs for any listeners; guarded on the session being unchanged in case an
      # event emitted during the unlink above already ended it.
      @_hover = nil if drop_hover
      @_arm = nil if drop_arm
      stale_drag.try { |d| drag_cancel d if @_drag == d }
      # Clear a stale drop-target pointing into the removed subtree, emitting the
      # expected `DragLeave` on it. Guarded on the session being unchanged, so it
      # is a no-op when the drag was already torn down above (its source was in
      # the subtree too) or ended by an event during the unlink.
      stale_target.try { |d| retarget(d, nil) if @_drag == d }
      # Release any input grab that pointed into the removed subtree, lifting the
      # stale modal lock so the rest of the screen takes mouse input again.
      stale_grabs.each { |g| ungrab g }
    end

    # :ditto:
    def >>(element)
      remove element
    end

    # Notifies `element`'s subtree that it now belongs to this screen, emitting
    # `Event::Attach` on every node (and `Event::Detach` from `previous` first,
    # if it was on a different screen).
    #
    # This only emits events; it does not store the screen on any node. The
    # caller links the tree (`#parent`/`#screen=`) beforehand, after which the
    # whole subtree derives its screen via `Widget#screen?`. Because the subtree
    # shares a single owning screen, the attach is uniform: either the whole
    # subtree moved here, or (when `previous == self`) nothing changed.
    def attach(element, previous : ::Crysterm::Screen? = nil)
      return if previous == self

      element.self_and_each_descendant do |el|
        el.emit Crysterm::Event::Detach, previous if previous
        el.emit Crysterm::Event::Attach, self
      end
    end

    # Notifies `element`'s subtree that it no longer belongs to `previous`
    # (defaulting to this screen), emitting `Event::Detach` on every node.
    #
    # Like `#attach`, this only emits events; the caller unlinks the tree
    # (`#parent`/`#screen=`) beforehand.
    def detach(element, previous : ::Crysterm::Screen? = nil)
      previous ||= self

      element.self_and_each_descendant do |el|
        el.emit Crysterm::Event::Detach, previous
      end
    end
  end
end
