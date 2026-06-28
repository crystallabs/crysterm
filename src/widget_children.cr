module Crysterm
  class Widget
    # Widget-specific parts of parent/children functionality

    include Mixin::Children

    # Transient guard set by `#insert` only while it re-homes a widget that is
    # staying on the *same* screen. The unlink it triggers (`#remove`) reads it to
    # skip the screen-level `Detach`, and `#insert` likewise skips the matching
    # `Attach`. On such a move the widget never actually leaves the screen, so
    # firing those screen-transition events would wrongly run `Attach`/`Detach`
    # handlers for what is really just a position change in the tree — e.g. a
    # `Media` overlay clearing its still-visible on-screen image, an überzug image
    # being removed, or a `TabWidget` carousel / `Table` data-load restarting.
    # Defaults false, and `#insert` always resets it right after the unlink, so no
    # other caller of `#remove` is affected.
    protected property? reparenting_same_screen : Bool = false

    # Removes node from its parent.
    # This is identical to calling `parent.remove(self)`.
    def remove_from_parent
      @parent.try(&.remove(self))
    end

    # Inserts `element` to list of children at a specified position (at end by default)
    def insert(element, i = -1)
      # A widget can never become a child of itself or of one of its own
      # descendants: that would splice a *cycle* into the tree — `element` would
      # end up both an ancestor and a child of `self` — so every parent/descendant
      # walk (`#screen?`, `#has_descendant?`, `#invalidate_screen_cache`, the
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

      # A *nested* move that keeps the widget on this same screen must not churn
      # the screen-level `Detach`/`Attach` events: the widget never leaves the
      # screen, so those would wrongly fire transition handlers (a `Media` overlay
      # clearing its image, a carousel restarting; see `#reparenting_same_screen?`)
      # for what is really just a tree-position change. Detected here, *before* the
      # unlink severs the `#parent` link the screen is derived through.
      dest_screen = screen?
      same_screen_move = !dest_screen.nil? && !element.parent.nil? && dest_screen == element.screen?

      # Detach the element from its current home first, so it isn't left
      # double-parented after being re-homed here. A *nested* element unlinks
      # from its widget parent (which also emits its `Detach` events — suppressed
      # for a same-screen move via the guard); a genuine *top-level* element — one
      # actually listed in a screen's `children`, which `remove_from_parent` can't
      # touch (it only follows a widget `@parent`) — is removed from that screen
      # instead. Without the latter branch, reparenting a top-level widget left it
      # in BOTH the old screen's `children` and the new parent's `children`
      # (rendered twice, inconsistent tree). This mirrors the same
      # detach-from-screen fallback `Widget#destroy` uses.
      if element.parent
        element.reparenting_same_screen = same_screen_move
        element.remove_from_parent
        element.reparenting_same_screen = false
      elsif (prev_screen = element.screen?) && prev_screen.children.includes?(element)
        prev_screen.remove element
      end

      # For a suppressed same-screen move, hand `attach` that shared screen so it
      # no-ops (`attach` returns early when `previous == self`), emitting no
      # redundant `Attach`. Otherwise `screen?` is still non-nil only for an
      # *unattached* element that merely holds the auto-assigned global screen but
      # was never added to any `children` (so neither branch above ran): that is
      # the screen it is moving away from, letting `attach` emit the right
      # cross-screen `Detach`/`Attach`.
      previous = same_screen_move ? dest_screen : element.screen?

      super
      # A nested widget derives its screen from `#parent`, so it must not keep a
      # stored reference of its own.
      element.screen = nil
      element.parent = self

      screen?.try &.attach(element, previous)

      element.emit Crysterm::Event::Reparent, self
      emit Crysterm::Event::Adopt, element
    end

    # Removes `element` from list of children
    def remove(element)
      return if element.parent != self

      # Whether the screen's keyboard focus currently lives inside the subtree
      # being detached. This MUST be sampled *before* `super`/the unlink runs:
      # once the tree is severed, a focused *descendant* (not `element` itself)
      # can no longer be related back to `element`, and the check would silently
      # miss it — leaving focus stranded on a now-detached, off-screen widget.
      s = screen?
      refocus = false
      if s && (f = s.focused)
        refocus = (f == element) || element.has_descendant?(f)
      end

      return unless super

      # Capture the screen the element is leaving *before* unlinking, so its
      # subtree can be told it has been detached.
      previous = element.screen?
      element.parent = nil
      element.screen = nil

      # TODO Enable
      # if i = screen.clickable.index(element)
      #  screen.clickable.delete_at i
      # end
      # if i = screen.keyable.index(element)
      #  screen.keyable.delete_at i
      # end

      element.emit(Crysterm::Event::Reparent, nil)
      emit(Crysterm::Event::Remove, element)

      # Skip the screen-level `Detach` when `#insert` is merely re-homing this
      # element within the *same* screen (see `#reparenting_same_screen?`): it
      # never leaves the screen, so the transition would be spurious. A normal
      # remove (the guard is false) detaches as usual.
      previous.try do |sc|
        sc.detach element, sc unless element.reparenting_same_screen?
      end

      # Rewind off the detached subtree after the unlink, using the condition
      # captured above so descendant focus is handled with correct timing.
      #
      # A same-screen reparent (see `#reparenting_same_screen?`) is exempt: the
      # subtree never leaves the screen and `#insert` re-homes it immediately
      # (synchronously, with no render in between), so its keyboard focus stays
      # valid throughout. Rewinding there would strand focus — popping the still-
      # on-screen widget out of the focus history and blurring it — on what is
      # really just a tree-position change, exactly the spurious churn the
      # screen-level `Detach` suppression above already avoids.
      s.rewind_focus if refocus && s && !element.reparenting_same_screen?
    end
  end
end
