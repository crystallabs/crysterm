module Crysterm
  class Widget
    # Widget-specific parts of parent/children functionality

    include Mixin::Children

    # Transient guard set while re-homing a widget that stays on the *same*
    # window: the unlink skips the window-level `Detach` and the focus rewind,
    # and the relink skips the matching `Attach`. The widget never actually
    # leaves the window, so firing those would wrongly run handlers for what is
    # just a tree-position change (a `Media` overlay clearing its image, a
    # `TabWidget` carousel restarting). Reset right after the unlink.
    protected property? reparenting_same_screen : Bool = false

    # Removes node from its parent.
    # This is identical to calling `parent.remove(self)`.
    def remove_from_parent
      @parent.try(&.remove(self))
    end

    # Detaches this widget from wherever it is actually attached. A nested widget
    # unlinks from its widget parent; a top-level one (no widget parent, but a
    # stored `@window`) is removed from that window instead, so the full teardown
    # — focus/hover/grab release — still runs.
    def detach_from_tree : Nil
      if @parent
        remove_from_parent
      else
        window?.try &.remove self
      end
    end

    # Tears down an owned *satellite* widget — one a control appends to the
    # *window* (a search box, a pop-up menu, a completion list, a hover tooltip)
    # rather than to itself, so the owner's `#destroy` never recurses into it.
    # The owner drops it here from its own teardown. Nil-safe.
    #
    # A class method so the non-widget `Completer` can call it too, and so it
    # reaches through the *satellite's own* `#window?` rather than the owner's —
    # which works even after the owner has already detached.
    def self.destroy_satellite(satellite : Widget?) : Nil
      return unless satellite
      satellite.window?.try &.remove satellite
      satellite.destroy
    end

    # Stretches *child* to fill this widget, `top`/`left`/`right`/`bottom` giving
    # the inset on each side (all `0` — flush — by default). Returns *child*.
    def fill_parent(child : Widget, *, top = 0, left = 0, right = 0, bottom = 0) : Widget
      child.top = top
      child.left = left
      child.right = right
      child.bottom = bottom
      child
    end

    # Installs *new_child* as this widget's single replaceable content child
    # (Qt's `setWidget` semantics), removing *old* first. Fills the parent with
    # the given insets, appends, and requests a render. Returns *new_child*.
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
      # descendants: that would splice a cycle into the tree and make every
      # parent/descendant walk recurse forever. Reject as a no-op before any
      # unlink/relink, matching Qt's `QWidget::setParent`. A genuine reorder (an
      # existing child at a new index) is unaffected.
      return if element.same?(self) || descendant_of?(element)

      # Must be detected before the unlink severs the `#parent` link the window
      # is derived through. A *top-level* element (parent nil) moving into a
      # widget on the same window counts as a same-window move too, and needs the
      # same suppression on the `Window#remove` path below.
      dest_screen = window?
      same_screen_move = !dest_screen.nil? && dest_screen == element.window?

      # When `element` is already a child of *this same* parent, the detach below
      # shifts the later siblings left, so a caller-supplied `i` computed against
      # the pre-removal list would land one slot too far. Capture the current
      # index now; the adjustment happens after removal.
      old_i = (element.parent == self) ? children.index(element) : nil

      # Detach from the current home first, so the element isn't left
      # double-parented. A top-level element is listed in a window's `children`,
      # which `remove_from_parent` can't touch, so it must go through the window
      # — otherwise reparenting it would leave it in both the old window's
      # `children` and the new parent's.
      if element.parent
        with_reparenting_guard(element, same_screen_move) { element.remove_from_parent }
      elsif (prev_screen = element.window?) && prev_screen.children.includes?(element)
        with_reparenting_guard(element, same_screen_move) { prev_screen.remove element }
      end

      # For a suppressed same-window move, hand `attach` that shared window so it
      # no-ops. Otherwise `window?` is non-nil only for an unattached element
      # holding the auto-assigned global window without being in any `children` —
      # the window it is moving away from, so `attach` emits the right
      # cross-window `Detach`/`Attach`.
      previous = same_screen_move ? dest_screen : element.window?

      # Same-parent reorder: adjust the now-stale insertion index.
      if oi = old_i
        i -= 1 if i >= 0 && oi < i
      end

      super element, i
      # A nested widget derives its window from `#parent`, so must not keep its
      # own stored reference.
      element.window = nil
      element.parent_ivar = self

      window?.try &.attach(element, previous)

      # Re-register in the window's keyboard/mouse registries: the unlink above
      # dropped the element, and construction-time registration only runs once, so
      # without this a reparented keyable widget stays out of `@keyable` and can
      # never be reached by Tab/Shift-Tab again. Registration is idempotent, and
      # covers the whole subtree — reparenting a *container* also detached its
      # keyable/clickable descendants.
      window?.try &.register_subtree(element)

      element.emit Crysterm::Event::Reparent, self
      emit Crysterm::Event::Adopt, element
    end

    # Runs the unlink in *block* with `element.reparenting_same_screen` set to
    # *same_screen_move*. The `ensure` reset matters: a raising handler in the
    # unlink would otherwise leak the flag into a later genuine remove/destroy.
    private def with_reparenting_guard(element, same_screen_move : Bool, &)
      element.reparenting_same_screen = same_screen_move
      begin
        yield
      ensure
        element.reparenting_same_screen = false
      end
    end

    # Removes `element` from list of children
    def remove(element)
      return if element.parent != self

      # Whether the window's keyboard focus lives inside the subtree being
      # detached. Must be sampled before the unlink: once the tree is severed, a
      # focused descendant can no longer be related back to `element`, silently
      # stranding focus on a detached widget.
      s = window?
      refocus = false
      if s && (f = s.focused)
        refocus = element.covers?(f)
      end

      return unless super

      # Capture the window the element is leaving *before* unlinking, so its
      # subtree can be told it has been detached.
      previous = element.window?
      element.parent_ivar = nil
      element.window = nil

      # Drop this element (and its subtree) from the window's keyboard/mouse
      # registries. Routed through `previous`, since the widget itself doesn't
      # own the lists. No-op when it was never on a window.
      previous.try &.unregister element

      element.emit(Crysterm::Event::Reparent, nil)
      emit(Crysterm::Event::Remove, element)

      # Tear down the window's transient mouse-state pointing into the detached
      # subtree — hover, press-arm, mouse captor, in-flight drag and modal grabs.
      # Without this a hovered/capturing/dragging nested widget that is removed
      # leaves the window pointing at a dead widget: stale `MouseOut`, mouse stuck
      # in capture, or modal-forever. Skipped for a same-window reparent, which
      # re-links immediately and keeps the pointers valid. The teardown brackets
      # the `detach`/rewind so stale pointers drop only after the subtree is
      # notified.
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

    # Order this widget was reached in during the current render walk. Transient
    # bookkeeping — NOT the widget's stacking position; for that see
    # `#stack_index=`, `#front!` and `#back!`.
    property render_index = -1

    # Sends widget to front
    def front!
      self.stack_index = -1
    end

    # Sends widget to back
    def back!
      self.stack_index = 0
    end

    # Moves this widget to slot *index* in its parent's children list — i.e. its
    # z-order among siblings (later siblings paint on top). Negative indexes
    # count from the end, so `-1` is frontmost. Out-of-range values clamp.
    def stack_index=(index : Int)
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
      # insert/remove path and thus `mark_structure_changed`. Without this, a lone
      # `front!`/`back!` under damage tracking leaves the dirty set empty, so the
      # new stacking order isn't painted until an unrelated full-frame trigger
      # fires, and order-dependent selectors (`:nth-child`, `:first`/`:last-child`,
      # sibling combinators) never re-evaluate.
      mark_dirty
      window?.try &.damage_force_full
      invalidate_css_tree

      true
    end
  end
end
