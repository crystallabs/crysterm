module Crysterm
  class Widget < ::Crysterm::Object
    # Is element hidden? Hidden elements are not rendered on the screen and their dimensions don't use screen space.
    setter visible = true

    # Shows widget on screen
    def show
      return if visible?
      @visible = false
      emit Crysterm::Event::Show
    end

    # Hides widget from screen
    def hide
      return unless visible?
      clear_pos
      @visible = false
      emit Crysterm::Event::Hide

      screen.try do |s|
        # s.rewind_focus if focused?
        s.rewind_focus if s.focused == self
      end
    end

    # Toggles widget visibility
    def toggle_visibility
      @visible ? hide : show
    end

    # Returns whether widget is visible. It also checks the complete chain of widget parents.
    def visible?
      # TODO Revert back to chained lookup eventually
      @visible
      # el = self
      # while el
      #  return false unless el.screen
      #  return false unless el.visible?
      #  el = el.parent
      # end
      # true
    end
  end
end
