module Crysterm
  class Widget
    # Widget-specific parts of parent/children functionality

    include Mixin::Children

    # Transient guard set by `#insert` only while it re-homes a widget that is
    # staying on the *same* window. The unlink it triggers (`#remove`) reads it to
    # skip the window-level `Detach`, and `#insert` likewise skips the matching
    # `Attach`. On such a move the widget never actually leaves the window, so
    # firing those window-transition events would wrongly run `Attach`/`Detach`
    # handlers for what is really just a position change in the tree — e.g. a
    # `Media` overlay clearing its still-visible on-window image, an überzug image
    # being removed, or a `TabWidget` carousel / `Table` data-load restarting.
    # Defaults false, and `#insert` always resets it right after the unlink, so no
    # other caller of `#remove` is affected.
    protected property? reparenting_same_screen : Bool = false

    # Removes node from its parent.
    # This is identical to calling `parent.remove(self)`.
    def remove_from_parent
      @parent.try(&.remove(self))
    end

    # Detaches this widget from wherever it is actually attached. A *nested*
    # widget unlinks from its widget parent (`#remove_from_parent`, which only
    # follows `@parent`); a *top-level* widget — one added straight onto a
    # `Window`, where it has no widget parent but holds a stored `@window` — is
    # removed from that window instead, so the full `Window#remove` teardown
    # (focus/hover/grab release) runs and it doesn't linger in `window.children`,
    # still painted and keyable. Used by `Widget#destroy` and the HTTP bridge's
    # `remove` command, which must each tear down a widget regardless of how it
    # was attached.
    def detach_from_tree : Nil
      if @parent
        remove_from_parent
      else
        window?.try &.remove self
      end
    end

    # Inserts `element` to list of children at a specified position (at end by default)
    def insert(element, i = -1)
      # A widget can never become a child of itself or of one of its own
      # descendants: that would splice a *cycle* into the tree — `element` would
      # end up both an ancestor and a child of `self` — so every parent/descendant
      # walk (`#window?`, `#has_descendant?`, `#invalidate_screen_cache`, the
      # renderer's traversal) would recurse forever and overflow the stack. The
      # damage is done immediately, the moment `element.parent = self` runs (its
      # `#invalidate_screen_cache` walks the now-cyclic subtree). Qt's
      # `QWidget::setParent` likewise refuses such a move; reject it as a no-op
      # here, before any unlink/relink. `self.has_ancestor?(element)` covers
      # `element` being any ancestor of `self`; the identity check covers
      # re-inserting `self` into itself. A genuine reorder (re-inserting an
      # existing *child* at a new index) is unaffected: a child is neither `self`
      # nor an ancestor of `self`.
      return if element.same?(self) || has_ancestor?(element)

      # A *nested* move that keeps the widget on this same window must not churn
      # the window-level `Detach`/`Attach` events: the widget never leaves the
      # window, so those would wrongly fire transition handlers (a `Media` overlay
      # clearing its image, a carousel restarting; see `#reparenting_same_screen?`)
      # for what is really just a tree-position change. Detected here, *before* the
      # unlink severs the `#parent` link the window is derived through.
      dest_screen = window?
      same_screen_move = !dest_screen.nil? && !element.parent.nil? && dest_screen == element.window?

      # Detach the element from its current home first, so it isn't left
      # double-parented after being re-homed here. A *nested* element unlinks
      # from its widget parent (which also emits its `Detach` events — suppressed
      # for a same-window move via the guard); a genuine *top-level* element — one
      # actually listed in a window's `children`, which `remove_from_parent` can't
      # touch (it only follows a widget `@parent`) — is removed from that window
      # instead. Without the latter branch, reparenting a top-level widget left it
      # in BOTH the old window's `children` and the new parent's `children`
      # (rendered twice, inconsistent tree). This mirrors the same
      # detach-from-window fallback `Widget#destroy` uses.
      if element.parent
        element.reparenting_same_screen = same_screen_move
        element.remove_from_parent
        element.reparenting_same_screen = false
      elsif (prev_screen = element.window?) && prev_screen.children.includes?(element)
        prev_screen.remove element
      end

      # For a suppressed same-window move, hand `attach` that shared window so it
      # no-ops (`attach` returns early when `previous == self`), emitting no
      # redundant `Attach`. Otherwise `window?` is still non-nil only for an
      # *unattached* element that merely holds the auto-assigned global window but
      # was never added to any `children` (so neither branch above ran): that is
      # the window it is moving away from, letting `attach` emit the right
      # cross-window `Detach`/`Attach`.
      previous = same_screen_move ? dest_screen : element.window?

      super
      # A nested widget derives its window from `#parent`, so it must not keep a
      # stored reference of its own.
      element.window = nil
      element.parent = self

      window?.try &.attach(element, previous)

      element.emit Crysterm::Event::Reparent, self
      emit Crysterm::Event::Adopt, element
    end

    # Removes `element` from list of children
    def remove(element)
      return if element.parent != self

      # Whether the window's keyboard focus currently lives inside the subtree
      # being detached. This MUST be sampled *before* `super`/the unlink runs:
      # once the tree is severed, a focused *descendant* (not `element` itself)
      # can no longer be related back to `element`, and the check would silently
      # miss it — leaving focus stranded on a now-detached, off-window widget.
      s = window?
      refocus = false
      if s && (f = s.focused)
        refocus = (f == element) || element.has_descendant?(f)
      end

      return unless super

      # Capture the window the element is leaving *before* unlinking, so its
      # subtree can be told it has been detached.
      previous = element.window?
      element.parent = nil
      element.window = nil

      # TODO Enable
      # if i = window.clickable.index(element)
      #  window.clickable.delete_at i
      # end
      # if i = window.keyable.index(element)
      #  window.keyable.delete_at i
      # end

      element.emit(Crysterm::Event::Reparent, nil)
      emit(Crysterm::Event::Remove, element)

      # Skip the window-level `Detach` when `#insert` is merely re-homing this
      # element within the *same* window (see `#reparenting_same_screen?`): it
      # never leaves the window, so the transition would be spurious. A normal
      # remove (the guard is false) detaches as usual.
      previous.try do |sc|
        sc.detach element, sc unless element.reparenting_same_screen?
      end

      # Rewind off the detached subtree after the unlink, using the condition
      # captured above so descendant focus is handled with correct timing.
      #
      # A same-window reparent (see `#reparenting_same_screen?`) is exempt: the
      # subtree never leaves the window and `#insert` re-homes it immediately
      # (synchronously, with no render in between), so its keyboard focus stays
      # valid throughout. Rewinding there would strand focus — popping the still-
      # on-window widget out of the focus history and blurring it — on what is
      # really just a tree-position change, exactly the spurious churn the
      # window-level `Detach` suppression above already avoids.
      s.rewind_focus if refocus && s && !element.reparenting_same_screen?
    end
  end
end
