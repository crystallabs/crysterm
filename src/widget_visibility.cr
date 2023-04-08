module Crysterm
  class Widget
    # Shows widget on screen
    def show
      return if self.style.visible?
      self.style.visible = true
      emit Crysterm::Event::Show
    end

    # Hides widget from screen
    def hide
      return if !self.style.visible?
      clear_last_rendered_position
      self.style.visible = false
      emit Crysterm::Event::Hide

      screen.try do |s|
        # s.rewind_focus if focused?
        s.rewind_focus if s.focused == self
      end
    end

    # Toggles widget visibility
    def toggle_visibility
      self.style.visible? ? hide : show
    end

    # Returns whether widget is visible. Currently does not check if all parents are also visible.
    def visible?
      self.style.visible?
      # This version also checks the complete chain of widget parents:
      # visible = true
      # self_and_each_ancestor { |a| visible &&= a.style.visible? }
      # visible
    end
  end
end
