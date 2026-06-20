module Crysterm
  class Screen
    def insert(element, i = -1)
      # Prevents adding an element twice
      super || return

      # A top-level widget (added straight to a Screen) is the single element
      # that actually stores its screen; its descendants derive it from the
      # tree. `previous` lets `attach` emit a `Detach` if it is being moved here
      # from another screen.
      previous = element.screen?
      element.screen = self
      attach element, previous

      # XXX:
      # - Make sure this is undo-ed if widget is detached
      if element.input? || element.keyable?
        register_keyable element
      end

      if element.clickable?
        register_clickable element
      end

      unless self.focused
        # element.focus
        focus_next
      end
    end

    # :ditto:
    def <<(element)
      insert element
    end

    def remove(element)
      return if element.screen? != self

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
      previous = element.screen?
      element.screen = nil
      detach element, previous

      if focused == element
        rewind_focus
      end
    end

    # :ditto:
    def >>(element)
      remove element
    end

    # Notifies `element`'s subtree that it now belongs to this screen, emitting
    # `Event::Attach` on every node (and `Event::Detach` from `previous` first,
    # if it was on a different screen).
    #
    # This only emits events; it does not store the screen on any node. The
    # caller links the tree (`#parent`/`#screen=`) beforehand, after which the
    # whole subtree derives its screen via `Widget#screen?`. Because the subtree
    # shares a single owning screen, the attach is uniform: either the whole
    # subtree moved here, or (when `previous == self`) nothing changed.
    def attach(element, previous : ::Crysterm::Screen? = nil)
      return if previous == self

      element.self_and_each_descendant do |el|
        el.emit Crysterm::Event::Detach, previous if previous
        el.emit Crysterm::Event::Attach, self
      end
    end

    # Notifies `element`'s subtree that it no longer belongs to `previous`
    # (defaulting to this screen), emitting `Event::Detach` on every node.
    #
    # Like `#attach`, this only emits events; the caller unlinks the tree
    # (`#parent`/`#screen=`) beforehand.
    def detach(element, previous : ::Crysterm::Screen? = nil)
      previous ||= self

      element.self_and_each_descendant do |el|
        el.emit Crysterm::Event::Detach, previous
      end
    end
  end
end
