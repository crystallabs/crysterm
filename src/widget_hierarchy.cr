module Crysterm
  class Widget < ::Crysterm::Object
    # module Hierarchy

    # Widget's parent `Widget`, if any.
    property parent : Widget?
    # This must be defined here rather than in src/mixin/children.cr because classes
    # which have children do not necessarily also have a parent (e.g. `Screen`).

    # Screen owning this element, forced to non-nil.
    # Each element must belong to a Screen if it is to be rendered/displayed anywhere.
    # If you just want to test for `Screen`, use `#screen?`.
    property! screen : ::Crysterm::Screen?

    # Screen owning this element, if any.
    # Each element must belong to a Screen if it is to be rendered/displayed anywhere.
    getter? screen : ::Crysterm::Screen?

    # Removes node from its parent.
    # This is identical to calling `#remove` on the parent object.
    def remove_parent
      @parent.try { |p| p.remove self }
    end

    # Inserts `element` to list of children at a specified position (at end by default)
    def insert(element, i = -1)
      if element.screen != screen
        element.screen.try &.detach(element)
      end

      element.remove_parent

      super
      screen.try &.attach(element)

      element.parent = self

      element.emit Crysterm::Event::Reparent, self
      emit Crysterm::Event::Adopt, element
    end

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

    def determine_screen
      win = if Screen.total <= 1
              # This will use the first screen or create one if none created yet.
              # (Auto-creation helps writing scripts with less code.)
              Screen.global true
            elsif s = @parent
              while s && !(s.is_a? Screen)
                s = s.parent_or_screen
              end
              if s.is_a? Screen
                s
                # else
                #  raise Exception.new("No active screen found in parent chain.")
              end
            elsif Screen.total > 0
              Screen.instances[-1]
            end

      unless win
        raise Exception.new("No Screen found anywhere. Create one with Screen.new")
      end

      win
    end

    # Returns parent `Widget` (if any) or `Screen` to which the widget may be attached.
    # If the widget already is `Screen`, returns `nil`.
    def parent_or_screen
      return nil if Screen === self
      @parent || screen
    end
    # end
  end
end
