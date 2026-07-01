module Crysterm
  class Widget
    # Widget-specific parts of parent/children functionality

    include Mixin::Children

    # Transient guard set by `#insert` while re-homing a widget staying on the
    # *same* window. The unlink it triggers (`#remove`) reads it to skip the
    # window-level `Detach`, and `#insert` skips the matching `Attach` — since
    # the widget never actually leaves the window, firing those would wrongly
    # run handlers for what is just a tree-position change (e.g. a `Media`
    # overlay clearing its image, a `TabWidget` carousel restarting). Defaults
    # false; `#insert` resets it right after the unlink.
    protected property? reparenting_same_screen : Bool = false

    # Removes node from its parent.
    # This is identical to calling `parent.remove(self)`.
    def remove_from_parent
      @parent.try(&.remove(self))
    end

    # Detaches this widget from wherever it is actually attached. A nested
    # widget unlinks from its widget parent (`#remove_from_parent`, following
    # `@parent`); a top-level widget (added straight onto a `Window`, no widget
    # parent but a stored `@window`) is removed from that window instead, so
    # the full `Window#remove` teardown (focus/hover/grab release) runs. Used
    # by `Widget#destroy` and the HTTP bridge's `remove` command.
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
      # descendants: that would splice a cycle into the tree, making every
      # parent/descendant walk (`#window?`, `#has_descendant?`,
      # `#invalidate_screen_cache`, the renderer's traversal) recurse forever.
      # The damage happens the moment `element.parent = self` runs (its
      # `#invalidate_screen_cache` walks the now-cyclic subtree), so reject as a
      # no-op here before any unlink/relink, matching Qt's `QWidget::setParent`.
      # `has_ancestor?(element)` covers `element` being an ancestor of `self`;
      # the identity check covers re-inserting `self` into itself. A genuine
      # reorder (existing child at a new index) is unaffected.
      return if element.same?(self) || has_ancestor?(element)

      # A nested move that keeps the widget on this same window must not churn
      # the window-level `Detach`/`Attach` events (see
      # `#reparenting_same_screen?`). Detected here, before the unlink severs
      # the `#parent` link the window is derived through.
      dest_screen = window?
      same_screen_move = !dest_screen.nil? && !element.parent.nil? && dest_screen == element.window?

      # Detach the element from its current home first, so it isn't left
      # double-parented. A nested element unlinks from its widget parent
      # (Detach suppressed for a same-window move via the guard); a top-level
      # element (listed in a window's `children`, which `remove_from_parent`
      # can't touch) is removed from that window instead — otherwise reparenting
      # a top-level widget would leave it in both the old window's `children`
      # and the new parent's. Mirrors the fallback `Widget#destroy` uses.
      if element.parent
        element.reparenting_same_screen = same_screen_move
        element.remove_from_parent
        element.reparenting_same_screen = false
      elsif (prev_screen = element.window?) && prev_screen.children.includes?(element)
        prev_screen.remove element
      end

      # For a suppressed same-window move, hand `attach` that shared window so it
      # no-ops (returns early when `previous == self`). Otherwise `window?` is
      # non-nil only for an unattached element holding the auto-assigned global
      # window without being in any `children` — that's the window it's moving
      # away from, letting `attach` emit the right cross-window `Detach`/`Attach`.
      previous = same_screen_move ? dest_screen : element.window?

      super
      # A nested widget derives its window from `#parent`, so must not keep its
      # own stored reference.
      element.window = nil
      element.parent = self

      window?.try &.attach(element, previous)

      element.emit Crysterm::Event::Reparent, self
      emit Crysterm::Event::Adopt, element
    end

    # Removes `element` from list of children
    def remove(element)
      return if element.parent != self

      # Whether the window's keyboard focus lives inside the subtree being
      # detached. Must be sampled before `super`/the unlink runs: once the tree
      # is severed, a focused descendant can no longer be related back to
      # `element`, silently stranding focus on a detached widget.
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

      # Skip the window-level `Detach` when `#insert` is re-homing this element
      # within the same window (see `#reparenting_same_screen?`). A normal
      # remove (guard false) detaches as usual.
      previous.try do |sc|
        sc.detach element, sc unless element.reparenting_same_screen?
      end

      # Rewind off the detached subtree after the unlink, using the condition
      # captured above for correct timing.
      #
      # A same-window reparent is exempt (see `#reparenting_same_screen?`):
      # `#insert` re-homes it immediately and synchronously, so focus stays
      # valid. Rewinding there would strand focus on a tree-position change,
      # the same spurious churn the `Detach` suppression above avoids.
      s.rewind_focus if refocus && s && !element.reparenting_same_screen?
    end

    # Widget's position in the stack (front, back). Render index / order.

    property index = -1

    # Sends widget to front
    def front!
      set_index -1
    end

    # Sends widget to back
    def back!
      set_index 0
    end

    def set_index(index : Int)
      # A top-level widget has no `@parent` (a `Window` is not a `Widget`), so
      # fall back to the window, otherwise `front!`/`back!` would no-op for it.
      return unless parent = (@parent || window?)

      if index < 0
        index = parent.children.size + index
      end

      index = Math.max index, 0
      index = Math.min index, parent.children.size - 1

      i = parent.children.index self

      return unless i

      parent.children.insert index, parent.children.delete_at i

      true
    end
  end
end
