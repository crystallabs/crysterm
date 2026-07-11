module Crysterm
  class Widget
    # Widget-specific parts of parent/children functionality

    include Mixin::Children

    # Transient guard set by `#insert` while re-homing a widget staying on the
    # *same* window. The unlink it triggers (`Widget#remove` for a nested
    # widget, `Window#remove` for a top-level one) reads it to skip the
    # window-level `Detach` and the focus rewind, and `#insert` skips the
    # matching `Attach` — since the widget never actually leaves the window,
    # firing those would wrongly run handlers for what is just a tree-position
    # change (e.g. a `Media` overlay clearing its image, a `TabWidget` carousel
    # restarting). Defaults false; `#insert` resets it right after the unlink.
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

    # Tears down an owned *satellite* widget — one a control appends to the
    # *window* (a search box, a pop-up menu, a completion/dropdown list, a hover
    # tooltip) rather than to itself, so the owner's own `#destroy` (which only
    # recurses into its children) never reaches it. The owner drops it here from
    # its own teardown.
    #
    # A class method (not an instance method) so the non-widget `Completer` can
    # call it too, and so it reaches through the *satellite's own* `#window?`
    # rather than the owner's — the robust choice: it works even after the owner
    # has already detached. `#destroy` self-detaches from the window as well, so
    # the explicit `#remove` is belt-and-suspenders. Nil-safe.
    def self.destroy_satellite(satellite : Widget?) : Nil
      return unless satellite
      satellite.window?.try &.remove satellite
      satellite.destroy
    end

    # Stretches *child* to fill this widget, `top`/`left`/`right`/`bottom`
    # giving the inset on each side (all `0` — flush — by default). This is the
    # geometry idiom the paged and single-content containers all share, where a
    # child fills the parent with a per-container offset on one side (a tab
    # bar's height, a dock title row, a splash message line). Returns *child*.
    def fill_parent(child : Widget, *, top = 0, left = 0, right = 0, bottom = 0) : Widget
      child.top = top
      child.left = left
      child.right = right
      child.bottom = bottom
      child
    end

    # Installs *new_child* as this widget's single replaceable content child
    # (Qt's `setWidget` semantics), removing *old* first. Fills the parent with
    # the given insets (see `#fill_parent`), appends, and requests a render.
    # Returns *new_child* so the caller can store it. Used by
    # `SplashScreen#content_widget=` and `DockWidget#widget=`.
    def replace_content_child(old : Widget?, new_child : Widget, *,
                              top = 0, left = 0, right = 0, bottom = 0) : Widget
      old.try &.remove_from_parent
      fill_parent new_child, top: top, left: left, right: right, bottom: bottom
      append new_child
      request_render
      new_child
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
      # No `element.parent` requirement: a *top-level* element (direct child of
      # the window, parent nil) moving into a widget on the same window is just
      # as much a same-window move, and must get the same suppression on the
      # `Window#remove` unlink path below.
      dest_screen = window?
      same_screen_move = !dest_screen.nil? && dest_screen == element.window?

      # When `element` is already a child of *this same* parent, detaching it
      # below shifts the later siblings left, so the caller-supplied `i` (computed
      # against the pre-removal list by `insert_before`/`insert_after`) would land
      # one slot too far. Capture its current index now and, once removal has
      # shifted things, decrement `i` when `element` sat before it.
      old_i = (element.parent == self) ? children.index(element) : nil

      # Detach the element from its current home first, so it isn't left
      # double-parented. A nested element unlinks from its widget parent
      # (Detach suppressed for a same-window move via the guard); a top-level
      # element (listed in a window's `children`, which `remove_from_parent`
      # can't touch) is removed from that window instead — otherwise reparenting
      # a top-level widget would leave it in both the old window's `children`
      # and the new parent's. Mirrors the fallback `Widget#destroy` uses. The
      # guard is set around both unlink flavors (`Window#remove` honors it just
      # like `Widget#remove`), and reset in `ensure` so a raising handler in the
      # unlink can't leak it into a later genuine remove/destroy.
      if element.parent
        element.reparenting_same_screen = same_screen_move
        begin
          element.remove_from_parent
        ensure
          element.reparenting_same_screen = false
        end
      elsif (prev_screen = element.window?) && prev_screen.children.includes?(element)
        element.reparenting_same_screen = same_screen_move
        begin
          prev_screen.remove element
        ensure
          element.reparenting_same_screen = false
        end
      end

      # For a suppressed same-window move, hand `attach` that shared window so it
      # no-ops (returns early when `previous == self`). Otherwise `window?` is
      # non-nil only for an unattached element holding the auto-assigned global
      # window without being in any `children` — that's the window it's moving
      # away from, letting `attach` emit the right cross-window `Detach`/`Attach`.
      previous = same_screen_move ? dest_screen : element.window?

      # Same-parent reorder: adjust the now-stale insertion index (see `old_i`).
      if oi = old_i
        i -= 1 if i >= 0 && oi < i
      end

      super element, i
      # A nested widget derives its window from `#parent`, so must not keep its
      # own stored reference.
      element.window = nil
      element.parent = self

      window?.try &.attach(element, previous)

      # Re-register the reparented element in the window's keyboard/mouse
      # registries. `#remove` unlinked it via `Window#unregister` when detaching
      # from its old parent, and construction-time registration (`Widget#initialize`)
      # only runs once — so without this a reparented keyable widget is stranded
      # out of `@keyable` and can never be reached by Tab/Shift-Tab again (its
      # `keyable?` flag stays true, but `@keyable` — the sole reader in
      # `focus_offset`/`focus_next`/`focus_previous` — no longer lists it).
      # Mirrors the registration `Window#insert` performs for a top-level widget;
      # predicate and `keyable?` inclusion match that gate. `register_keyable`/
      # `register_clickable` no-op if the element is already listed.
      #
      # Walks `self_and_each_descendant` (mirroring `Window#unregister`, which
      # drops the whole subtree): reparenting a *container* also detached its
      # keyable/clickable descendants, so re-registering only the container root
      # would strand them out of `@keyable`/`@clickable` forever.
      window?.try &.register_subtree(element)

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
        refocus = element.covers?(f)
      end

      return unless super

      # Capture the window the element is leaving *before* unlinking, so its
      # subtree can be told it has been detached.
      previous = element.window?
      element.parent = nil
      element.window = nil

      # Drop this element (and its subtree) from the window's keyboard/mouse
      # registries. Routed through `previous` (captured above) since the widget
      # itself doesn't own the lists. No-op when it was never on a window. See
      # `Window#unregister`.
      previous.try &.unregister element

      element.emit(Crysterm::Event::Reparent, nil)
      emit(Crysterm::Event::Remove, element)

      # Tear down the window's transient mouse-state pointing into the detached
      # subtree — hover, press-arm, mouse captor, in-flight drag and modal grabs
      # — exactly as `Window#remove` does for a top-level child. Without this a
      # hovered/capturing/dragging *nested* widget that is removed (directly, or
      # via `Widget#destroy` → `detach_from_tree`) leaves the window pointing at
      # a dead widget: stale `MouseOut`, mouse stuck in capture, or modal-forever
      # (see BUGS14-C2). Skipped for a same-window reparent (`#insert` re-links
      # immediately, so the pointers stay valid) — the same guard the `Detach`
      # and focus-rewind below use. The teardown brackets the `detach`/rewind so
      # the stale pointers are dropped after the subtree is notified, mirroring
      # `Window#remove`'s ordering.
      if (sc = previous) && !element.reparenting_same_screen?
        sc.release_transient_state_for(element) do
          sc.detach element, sc
          s.rewind_focus if refocus && s
        end
      else
        # Same-window reparent, or the element was never on a window: only the
        # (guarded) `Detach`/rewind, no mouse-state teardown.
        previous.try do |pv|
          pv.detach element, pv unless element.reparenting_same_screen?
        end
        s.rewind_focus if refocus && s && !element.reparenting_same_screen?
      end
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

      # No-op when the widget is already at the target slot: avoid churning
      # damage/CSS for a stacking change that isn't one.
      return true if i == index

      parent.children.insert index, parent.children.delete_at i

      # A pure z-order reorder mutates the children list directly, bypassing the
      # `Mixin::Children#insert`/`#remove` path and thus `mark_structure_changed`.
      # Without this, under `OptimizationFlag::DamageTracking` a lone `front!`/
      # `back!` leaves the dirty set empty, so `damage_try_composite` returns a
      # fast frame and the new stacking order isn't painted until an unrelated
      # full-frame trigger fires. Order-dependent selectors (`:nth-child`,
      # `:first`/`:last-child`, sibling combinators) also wouldn't re-evaluate.
      # Mirror what `mark_structure_changed` does: force a full re-composite and
      # re-parse the affected subtree (covers siblings via the parent subtree).
      mark_dirty
      window?.try &.damage_force_full
      invalidate_css_tree

      true
    end
  end
end
