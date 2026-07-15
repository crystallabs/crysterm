module Crysterm
  class Window
    def insert(element, i = -1)
      # Reorder of an existing top-level child (`prepend`/`insert_before`/
      # `insert_after` on a widget already listed here). The bare
      # `Mixin::Children#insert` rejects a duplicate before any list mutation, so
      # it can't reposition (a plain `super || return` would make a reorder a
      # silent no-op). Do the remove-then-add in place, mirroring `Widget#insert`.
      # The widget stays on this same window, so none of the attach/detach/focus/
      # registry churn is needed; just relist and mark the structure changed.
      if old_i = children.index(element)
        # Correct the caller's index (computed against the pre-removal list) for
        # the removal that shifts later siblings left, then normalize a negative
        # (append) target against the post-removal list. Mirrors `Widget#insert`'s
        # F1-14 index correction.
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
      # window. Detected before the unlink severs the `#parent` link the window is
      # derived through. (A cross-window move keeps the normal churn.)
      same_screen_move = !element.parent.nil? && element.window? == self

      # An element moved here from another home must first be unlinked from it,
      # or it is left double-parented — listed in both its old container's
      # `children` and ours (rendered twice, stale repaints on the old
      # container). A *nested* element unlinks from its widget parent (Detach
      # suppressed for a same-window move via `reparenting_same_screen`, as
      # `Widget#insert` does); a genuine *top-level* element (listed directly in
      # another screen's `children`, which `remove_from_parent` can't touch since
      # it has no widget `@parent`) is removed from that screen instead.
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
      # `previous` lets `attach` emit a `Detach` if moved here from another
      # screen. For a same-window move hand `attach` this window so it no-ops
      # (returns early when `previous == self`), suppressing the spurious
      # `Attach`. Otherwise the unlink above already detached it from its old home
      # (emitting `Detach`), so `previous` is now nil and `attach` just emits
      # `Attach`.
      previous = same_screen_move ? self : element.window?
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
      # Walks `self_and_each_descendant` (mirroring `#unregister`, which drops the
      # whole subtree on removal): inserting a *container* moved here from another
      # screen must re-register its keyable/clickable descendants too, else they
      # stay stranded out of `@keyable`/`@clickable`. `register_*` no-op on dupes.
      register_subtree element

      # Auto-focus on insert, but only when the inserted widget can itself take
      # focus. Inserting non-interactive chrome (a decorative box, a `Line`, the
      # transient drag ghost — see `window_drag.cr#make_ghost`) into a screen
      # with no current focus must not yank focus onto an unrelated,
      # pre-existing keyable widget that merely happens to be unfocused. An
      # unconditional `focus_next` would do exactly that: adding a plain `Box`
      # would re-focus some earlier widget that nothing had selected. Gating on
      # the new element wanting keyboard focus keeps "the first real focusable
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
      # Only a *direct* top-level child of this window can be removed here. A
      # guard like `element.window? != self` would pass for any widget anywhere in
      # the tree, so `remove(nested_widget)` would make `super` a no-op yet still
      # run `unregister`/`detach`/`rewind_focus` on a still-attached subtree,
      # corrupting nav/focus. Mirror `#insert`'s membership gate: a non-child is a
      # no-op. (`@children_set` is `Mixin::Children`'s O(1) membership index.)
      return unless @children_set.includes? element

      # Whether keyboard focus currently lives inside the subtree being removed.
      # Must be sampled *before* the unlink below: once `element.window = nil`
      # severs the tree, a focused *descendant* can no longer be related back to
      # `element` via `#covers?`, silently stranding focus on a
      # now-detached widget.
      refocus = (f = focused) && element.covers?(f)

      super

      # Drop this element (and its subtree) from the keyboard/mouse registries so
      # detached widgets don't linger in `@keyable`/`@clickable`. See `#unregister`.
      unregister element

      # A same-window re-home (`Widget#insert` pulling this top-level widget
      # into a container on this same window — see
      # `Widget#reparenting_same_screen?`) is a tree-position change, not a
      # departure: skip the window-level `Detach`, the focus rewind and the
      # transient mouse-state teardown, exactly as `Widget#remove` does for the
      # nested flavor. Only the unlink above is wanted — the caller re-links and
      # re-registers the subtree immediately (`register_subtree`), so focus,
      # hover, drag and grab pointers into it stay valid throughout.
      if element.reparenting_same_screen?
        element.window = nil
        return
      end

      # Clear the stored reference on this (top-level) element, then — bracketed
      # by the transient mouse-state teardown (`#release_transient_state_for`,
      # shared with `Widget#remove`) — notify the subtree it has left this screen
      # and rewind focus. The teardown samples the stale hover/arm/captor/drag/
      # grab pointers into the subtree and drops them after the detach, so a
      # removed widget can't leave the window pointing at it. `covers?` is
      # invariant across the unlink (it walks the element's own children), so
      # sampling after `super`/`window = nil` yields the same relations as before.
      previous = element.window?
      element.window = nil
      release_transient_state_for(element) do
        detach element, previous
        rewind_focus if refocus
      end
    end

    # Re-registers `element` and its descendants in the keyboard/mouse
    # registries (`@keyable`/`@clickable`). Shared by `Window#insert` (a
    # top-level widget/container moved or added here) and `Widget#insert` (a
    # nested reparent onto a widget already on this window) — both need the
    # whole subtree re-registered, not just the root, or descendants stay
    # stranded out of `@keyable`/`@clickable`. `register_keyable`/
    # `register_clickable` no-op on dupes.
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
      # window's revert-to-pristine pass (see `#css_note_styled_attach`), or a
      # rule-less window renders the old window's theme on it indefinitely.
      # Checked on every non-same-window attach (not just `previous != nil`):
      # the reparent flows unlink from the old window first, so `previous` is
      # already nil by the time `attach` runs.
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
