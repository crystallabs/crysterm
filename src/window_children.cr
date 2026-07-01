module Crysterm
  class Window
    def insert(element, i = -1)
      # Prevents adding an element twice
      super || return

      # An element moved here from another home must first be unlinked from it,
      # or it is left double-parented — listed in both its old container's
      # `children` and ours (rendered twice, stale repaints on the old
      # container). A *nested* element unlinks from its widget parent; a
      # genuine *top-level* element (listed directly in another screen's
      # `children`, which `remove_from_parent` can't touch since it has no
      # widget `@parent`) is removed from that screen instead. Mirrors the
      # detach-from-old-home `Widget#insert` performs for the reverse move;
      # without it, moving a widget *onto* a screen leaked.
      if element.parent
        element.remove_from_parent
      elsif (prev_screen = element.window?) && prev_screen != self && prev_screen.children.includes?(element)
        prev_screen.remove element
      end

      # A top-level widget (added straight to a Window) is the single element
      # that actually stores its screen; descendants derive it from the tree.
      # `previous` lets `attach` emit a `Detach` if moved here from another
      # screen. The unlink above already detached it from its old home (emitting
      # that `Detach`), so `previous` is now nil and `attach` just emits `Attach`.
      previous = element.window?
      element.window = self
      attach element, previous

      # XXX:
      # - Make sure this is undo-ed if widget is detached
      #
      # Mirrors the real focus-registration predicate (`@keys || @input`, see
      # `widget.cr` where `register_keyable` is called on construction), plus the
      # already-registered `keyable?` flag for a widget being *moved* here from
      # another screen. A widget built with `keys: true` has `keys? == true` but
      # `keyable? == false` until registered, and the screen-parented case reaches
      # this `insert` (via `Widget#initialize`'s `append`) before that
      # construction-time registration runs — so without `keys?` here such a
      # widget would never get registered, and the auto-focus gate below
      # (needing it in `@keyable`) could never focus it.
      if element.keys? || element.input? || element.keyable?
        register_keyable element
      end

      if element.clickable?
        register_clickable element
      end

      # Auto-focus on insert, but only when the inserted widget can itself take
      # focus. Inserting non-interactive chrome (a decorative box, a `Line`, the
      # transient drag ghost — see `window_drag.cr#make_ghost`) into a screen
      # with no current focus must not yank focus onto an unrelated,
      # pre-existing keyable widget that merely happens to be unfocused. The old
      # unconditional `focus_next` did exactly that: adding a plain `Box`
      # re-focused some earlier widget that nothing had selected. Gating on the
      # new element wanting keyboard focus keeps "the first real focusable
      # widget added gets focus" while making an unfocusable insert
      # focus-neutral.
      #
      # The predicate must match the registration gate above (`keys? || input? ||
      # keyable?`), not a bare `keyable?`: a `keys: true` widget reaches here with
      # `keyable? == false` until `register_keyable` runs just above, so a
      # `keyable?`-only gate would never fire for it.
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
      return if element.window? != self

      # Whether keyboard focus currently lives inside the subtree being removed.
      # Must be sampled *before* the unlink below: once `element.window = nil`
      # severs the tree, a focused *descendant* can no longer be related back to
      # `element` via `has_descendant?`, silently stranding focus on a
      # now-detached widget.
      refocus = (f = focused) && (f == element || element.has_descendant?(f))

      # Transient mouse-interaction pointers into the subtree go stale the same
      # way, and must be dropped too: `screen.hovered` would keep reporting a
      # detached widget, a pending press would call `start_drag` on it, and an
      # in-flight drag whose source is removed would stay modal forever (every
      # mouse event swallowed by the `@_drag` branch of `#dispatch_mouse`).
      # Sampled here for the same `has_descendant?` reason as `refocus`.
      drop_hover = (h = @_hover) && (h == element || element.has_descendant?(h))
      drop_arm = (a = @_arm) && (a == element || element.has_descendant?(a))
      # A widget that captured the mouse (`#capture_mouse`, e.g. an in-flight
      # text drag-select) and is then removed before button-up would keep
      # `@_mouse_captor` pointing at a detached widget, routing every subsequent
      # Move/Up to it forever (the capture branch of `#dispatch_mouse`) — the
      # same "modal forever" hazard as `@_drag`.
      drop_captor = (c = @_mouse_captor) && (c == element || element.has_descendant?(c))
      stale_drag = ((d = @_drag) && (d.source == element || element.has_descendant?(d.source))) ? d : nil
      # An in-flight drag whose drop target (not source) sits in the removed
      # subtree would keep `@_drag.target` pointing at a detached widget — a
      # later drop would emit `Event::Drop` on an off-screen widget, since a drag
      # only re-evaluates its target on motion. Cleared below via retarget(nil).
      stale_target = ((td = @_drag) && (tg = td.target) && (tg == element || element.has_descendant?(tg))) ? td : nil
      # An active input grab (an open modal pop-up — see `Window#grab`) whose
      # widget sits in the removed subtree must be released. A direct `remove`
      # bypasses the pop-up's own `ungrab`, leaving `@grabs` pointing at a
      # detached widget and modally blocking the rest of the screen forever.
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
      previous = element.window?
      element.window = nil
      detach element, previous

      rewind_focus if refocus

      # Drop the stale mouse pointers sampled above. The drag is torn down via
      # `#drag_cancel` (not just nilled) so its `DragEnd`/`DragLeave` cleanup
      # still runs; guarded on the session being unchanged in case an event
      # during the unlink above already ended it.
      @_hover = nil if drop_hover
      # The removed widget may have owned the GUI mouse-pointer shape (OSC 22 —
      # see `Widget#mouse_cursor_shape=`), pushed on `MouseOver` and normally
      # reverted on `MouseOut`. A removal emits no `MouseOut`, so restore it here
      # too (no-op unless a non-default shape is actually applied).
      set_mouse_cursor_shape nil if drop_hover
      @_arm = nil if drop_arm
      @_mouse_captor = nil if drop_captor
      stale_drag.try { |sd| drag_cancel sd if @_drag == sd }
      # Clear a stale drop-target pointing into the removed subtree, emitting
      # the expected `DragLeave`. No-op if the drag was already torn down above.
      stale_target.try { |st| retarget(st, nil) if @_drag == st }
      # Release any input grab that pointed into the removed subtree, lifting
      # the stale modal lock.
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
    # Only emits events; does not store the screen on any node — the caller
    # links the tree (`#parent`/`#screen=`) beforehand, after which the subtree
    # derives its screen via `Widget#window?`.
    def attach(element, previous : ::Crysterm::Window? = nil)
      return if previous == self

      element.self_and_each_descendant do |el|
        el.emit Crysterm::Event::Detach, previous if previous
        el.emit Crysterm::Event::Attach, self
      end
    end

    # Notifies `element`'s subtree that it no longer belongs to `previous`
    # (defaulting to this screen), emitting `Event::Detach` on every node.
    #
    # Like `#attach`, only emits events; the caller unlinks the tree beforehand.
    def detach(element, previous : ::Crysterm::Window? = nil)
      previous ||= self

      element.self_and_each_descendant do |el|
        el.emit Crysterm::Event::Detach, previous
      end
    end
  end
end
