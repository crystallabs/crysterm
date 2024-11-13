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
      if element.screen != screen
        element.screen.try &.detach(element)
      end

      element.remove_from_parent

      super
      screen.try &.attach(element)

      element.parent = self

      element.emit Crysterm::Event::Reparent, self
      emit Crysterm::Event::Adopt, element
    end

    # Removes `element` from list of children
    def remove(element)
      return if element.parent != self

      return unless super
      element.parent = nil

      # TODO Enable
      # if i = screen.clickable.index(element)
      #  screen.clickable.delete_at i
      # end
      # if i = screen.keyable.index(element)
      #  screen.keyable.delete_at i
      # end

      element.emit(Crysterm::Event::Reparent, nil)
      emit(Crysterm::Event::Remove, element)
      # s= screen
      # raise Exception.new() unless s
      # screen_clickable= s.clickable
      # screen_keyable= s.keyable

      screen.try do |s|
        s.detach element

        if s.focused == element
          s.rewind_focus
        end
      end
    end
  end
end
