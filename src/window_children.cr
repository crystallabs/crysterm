module Crysterm
  class Window
    def insert(element, i = -1)
      # Reorder of an existing top-level child. `Mixin::Children#insert` rejects
      # a duplicate before mutating the list, so it can't reposition; do the
      # remove-then-add here. The widget stays on this window, so no attach/
      # detach/focus/registry churn is needed.
      if old_i = children.index(element)
        # Correct the caller's index (computed against the pre-removal list) for
        # the removal that shifts later siblings left, then normalize a negative
        # (append) target against the post-removal list.
        target = i
        target -= 1 if target >= 0 && old_i < target
        children.delete_at old_i
        target += children.size + 1 if target < 0
        children.insert target.clamp(0, children.size), element
        mark_structure_changed
        return element
      end

      # A same-window nested→top-level move must not churn the window-level
      # `Detach`/`Attach` events or rewind focus — the widget never leaves this
      # window. Must be sampled before the unlink severs the `#parent` link the
      # window is derived through.
      same_screen_move = !element.parent.nil? && element.window? == self

      # An element moved here from another home must first be unlinked from it,
      # or it stays double-parented — listed in both its old container's
      # `children` and ours (rendered twice, stale repaints on the old
      # container). A *nested* element unlinks from its widget parent; a
      # *top-level* one has no widget `@parent` for `remove_from_parent` to
      # touch, so it is removed from its old screen instead.
      if element.parent
        element.reparenting_same_screen = same_screen_move
        begin
          element.remove_from_parent
        ensure
          element.reparenting_same_screen = false
        end
      elsif (prev_screen = element.window?) && prev_screen != self && prev_screen.children.includes?(element)
        prev_screen.remove element
      end

      # Prevents adding an element twice (any residual duplicate is a no-op).
      super || return

      # A top-level widget (added straight to a Window) is the single element
      # that actually stores its screen; descendants derive it from the tree.
      # For a same-window move hand `attach` this window so it no-ops,
      # suppressing a spurious `Attach`; otherwise the unlink above already
      # emitted `Detach`, leaving `previous` nil.
      previous = same_screen_move ? self : element.window?
      element.window = self
      attach element, previous

      # XXX:
      # - Make sure this is undo-ed if widget is detached
      #
      # The gate mirrors the construction-time focus-registration predicate
      # (`@keys || @input`), plus `keyable?` for a widget moved here already
      # registered. A widget built with `keys: true` reaches this `insert` (via
      # `Widget#initialize`'s `append`) before that registration runs, so a bare
      # `keyable?` would never register it. The whole subtree is walked: a
      # container moved here from another screen must re-register its keyable/
      # clickable descendants too. `register_*` no-op on dupes.
      register_subtree element

      # Auto-focus on insert, but only when the inserted widget can itself take
      # focus. An unconditional `focus_next` would let non-interactive chrome (a
      # decorative box, a `Line`, a transient drag ghost) yank focus onto an
      # unrelated pre-existing keyable widget that merely happens to be
      # unfocused. The predicate must match the registration gate above, not a
      # bare `keyable?`, for the `keys: true` case described there.
      if (element.keys? || element.input? || element.keyable?) && !self.focused
        focus_next
      end
    end

    # :ditto:
    def <<(element)
      insert element
    end

    def remove(element)
      # Only a *direct* top-level child of this window can be removed here. A
      # membership gate, not `element.window? != self`, which passes for any
      # widget in the tree: that would make `super` a no-op yet still run
      # `unregister`/`detach`/`rewind_focus` on a still-attached subtree,
      # corrupting nav/focus. (`@children_set` is the O(1) membership index.)
      return unless @children_set.includes? element

      # Whether keyboard focus currently lives inside the subtree being removed.
      # Must be sampled *before* the unlink below: once `element.window = nil`
      # severs the tree, a focused *descendant* can no longer be related back to
      # `element` via `#covers?`, silently stranding focus on a detached widget.
      refocus = (f = focused) && element.covers?(f)

      super

      # Drop this element (and its subtree) from the keyboard/mouse registries so
      # detached widgets don't linger in `@keyable`/`@clickable`.
      unregister element

      # A same-window re-home is a tree-position change, not a departure: skip
      # the window-level `Detach`, the focus rewind and the transient
      # mouse-state teardown. Only the unlink above is wanted — the caller
      # re-links and re-registers the subtree immediately, so focus, hover, drag
      # and grab pointers into it stay valid throughout.
      if element.reparenting_same_screen?
        element.window = nil
        return
      end

      # Clear the stored reference on this (top-level) element, then — bracketed
      # by the transient mouse-state teardown — notify the subtree it has left
      # this screen and rewind focus. The teardown samples the stale hover/arm/
      # captor/drag/grab pointers into the subtree and drops them after the
      # detach, so a removed widget can't leave the window pointing at it.
      # `covers?` walks the element's own children, so it is invariant across
      # the unlink and can be sampled here.
      previous = element.window?
      element.window = nil
      release_transient_state_for(element) do
        detach element, previous
        rewind_focus if refocus
      end
    end

    # Re-registers `element` and its descendants in the keyboard/mouse
    # registries (`@keyable`/`@clickable`). The whole subtree is re-registered,
    # not just the root, or descendants stay stranded out of the registries.
    # `register_keyable`/`register_clickable` no-op on dupes.
    def register_subtree(element) : Nil
      element.self_and_each_descendant do |e|
        register_keyable e if e.keys? || e.input? || e.keyable?
        register_clickable e if e.clickable?
      end
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

      # A subtree arriving pre-styled from another window must arm this
      # window's revert-to-pristine pass, or a rule-less window renders the
      # other window's theme on it indefinitely. Checked on every
      # non-same-window attach, not just `previous != nil`: the reparent flows
      # unlink from the old window first, so `previous` is already nil here.
      css_note_styled_attach element if element.is_a?(Widget)

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
