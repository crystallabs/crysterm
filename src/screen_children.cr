module Crysterm
  class Screen
    def insert(element, i = -1)
      # Prevents adding an element twice
      super || return

      # An element moved here from another home must first be unlinked from it,
      # or it is left double-parented — listed in BOTH its old container's
      # `children` and ours (rendered twice, inconsistent tree, and a stale
      # entry that keeps repainting on the old container). A *nested* element
      # unlinks from its widget parent; a genuine *top-level* element — one
      # listed directly in another screen's `children`, which `remove_from_parent`
      # can't touch (it has no widget `@parent`, only a stored screen) — is
      # removed from that screen instead. This mirrors the detach-from-old-home
      # `Widget#insert` performs for the reverse move (a top-level widget pulled
      # into a widget); without it, moving a widget *onto* a screen leaked.
      if element.parent
        element.remove_from_parent
      elsif (prev_screen = element.screen?) && prev_screen != self && prev_screen.children.includes?(element)
        prev_screen.remove element
      end

      # A top-level widget (added straight to a Screen) is the single element
      # that actually stores its screen; its descendants derive it from the
      # tree. `previous` lets `attach` emit a `Detach` if it is being moved here
      # from another screen. (The unlink above already detached it from its old
      # home, emitting that `Detach`, so `previous` is now nil and `attach` just
      # emits the `Attach` — no redundant or missing transition events.)
      previous = element.screen?
      element.screen = self
      attach element, previous

      # XXX:
      # - Make sure this is undo-ed if widget is detached
      #
      # Mirror the real focus-registration predicate (`@keys || @input`, see
      # `widget.cr` where `register_keyable` is called on construction) — plus the
      # already-registered `keyable?` flag for a widget being *moved* here from
      # another screen. A widget built with `keys: true` has `keys? == true` but
      # `keyable? == false` until registered, and the screen-parented case reaches
      # this `insert` (via `Widget#initialize`'s `append`) BEFORE that construction-
      # time registration runs — so without `keys?` here such a widget was never
      # registered during insert, and the auto-focus gate below (which needs it in
      # `@keyable`) could never focus it.
      if element.keys? || element.input? || element.keyable?
        register_keyable element
      end

      if element.clickable?
        register_clickable element
      end

      # Auto-focus on insert, but only when the inserted widget can itself take
      # focus. Inserting non-interactive chrome (a decorative box, a `Line`, the
      # transient drag ghost — see `screen_drag.cr#make_ghost`) into a screen that
      # currently has NO focus must not yank focus onto an unrelated, pre-existing
      # keyable widget that merely happens to be unfocused (e.g. one left so after
      # `rewind_focus` found no valid target, or after the history was cleared).
      # The old unconditional `focus_next` did exactly that: adding a plain `Box`
      # re-focused some earlier widget that nothing had selected. Gating on the new
      # top-level element wanting keyboard focus keeps the intended "the first real
      # focusable widget added gets focus" behavior, while making an unfocusable
      # insert focus-neutral.
      #
      # The predicate must match the registration gate above (`keys? || input? ||
      # keyable?`), NOT a bare `keyable?`: a `keys: true` widget reaches here with
      # `keyable? == false` (its flag is only set by the `register_keyable` just
      # run above), so a `keyable?`-only gate would never fire for it. With the
      # broad predicate it is both registered (above) and focused (here), exactly
      # like an `input: true` widget already was.
      if (element.keys? || element.input? || element.keyable?) && !self.focused
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
