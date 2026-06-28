module Crysterm
  class Widget
    # Widget-specific parts of parent/children functionality

    include Mixin::Children

    # Removes node from its parent.
    # This is identical to calling `parent.remove(self)`.
    def remove_from_parent
      @parent.try(&.remove(self))
    end

    # Inserts `element` to list of children at a specified position (at end by default)
    def insert(element, i = -1)
      # Detach the element from its current home first, so it isn't left
      # double-parented after being re-homed here. A *nested* element unlinks
      # from its widget parent (which also emits its `Detach` events); a genuine
      # *top-level* element — one actually listed in a screen's `children`, which
      # `remove_from_parent` can't touch (it only follows a widget `@parent`) — is
      # removed from that screen instead. Without the latter branch, reparenting a
      # top-level widget left it in BOTH the old screen's `children` and the new
      # parent's `children` (rendered twice, inconsistent tree); `attach` below
      # only emits events and, for a same-screen move, doesn't run at all. This
      # mirrors the same detach-from-screen fallback `Widget#destroy` uses.
      if element.parent
        element.remove_from_parent
      elsif (prev_screen = element.screen?) && prev_screen.children.includes?(element)
        prev_screen.remove element
      end

      # `screen?` is still non-nil only for an *unattached* element that merely
      # holds the auto-assigned global screen but was never added to any
      # `children` (so neither branch above ran): that is the screen it is moving
      # away from, letting `attach` emit the right cross-screen `Detach`/`Attach`.
      previous = element.screen?

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

      previous.try do |sc|
        sc.detach element, sc
      end

      # Rewind off the detached subtree after the unlink, using the condition
      # captured above so descendant focus is handled with correct timing.
      s.rewind_focus if refocus && s
    end
  end
end
