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
      # Detach the element from its current widget-parent first (if any). For a
      # nested element this also emits its `Detach` events.
      element.remove_from_parent

      # After unlinking, `screen?` is non-nil only if `element` was a *top-level*
      # widget (which `remove_from_parent` cannot detach): that is the screen it
      # is moving away from, so `attach` can emit the right `Detach`/`Attach`.
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
