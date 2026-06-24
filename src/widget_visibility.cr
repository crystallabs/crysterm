module Crysterm
  class Widget
    # Shows widget on screen
    def show
      return if self.style.visible?
      set_visible true
      mark_dirty
      emit Crysterm::Event::Show
    end

    # Hides widget from screen
    def hide
      return if !self.style.visible?
      # No need to erase the old footprint here: `Screen#_render` clears the
      # whole cell buffer before each frame, so a now-hidden widget simply
      # stops repainting and its old cells are gone on the next render.
      set_visible false
      mark_dirty
      emit Crysterm::Event::Hide

      screen?.try do |s|
        # s.rewind_focus if focused?
        s.rewind_focus if s.focused == self
      end
    end

    # Sets visibility on the active style and, when CSS has taken over styling
    # (`css_styled?`), also persists it onto the inline `@style`. Without that,
    # the change would land only on the computed per-state style and be discarded
    # by the next cascade (which rebuilds from the pristine base + inline fold) —
    # making the widget reappear/disappear on any restyle.
    private def set_visible(value : Bool) : Nil
      self.style.visible = value
      (@style ||= ::Crysterm::Style.new).visible = value if css_styled?
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
