module Crysterm
  class Widget < ::Crysterm::Object
    # Is element hidden? Hidden elements are not rendered on the screen and their dimensions don't use screen space.
    property? hidden = false

    # Shows widget on screen
    def show
      return unless @hidden
      @hidden = false
      emit Crysterm::Event::Show
    end

    # Hides widget from screen
    def hide
      return if @hidden
      clear_pos
      @hidden = true
      emit Crysterm::Event::Hide
      # screen.rewind_focus if focused?
      screen.rewind_focus if screen.focused == self
    end

    # Toggles widget visibility
    def toggle_visibility
      @hidden ? show : hide
    end

    # Returns whether widget is visible. This is different from `#hidden?`
    # because it checks the complete chain of widget parents.
    def visible?
      el = self
      while el
        return false unless el.screen
        return false if el.hidden?
        el = el.parent
      end
      true
    end
  end
end
