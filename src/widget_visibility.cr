module Crysterm
  class Widget
    # Shows widget on window
    def show
      return if self.state_style.visible?
      set_visible true
      mark_dirty
      emit Crysterm::Event::Show
      # Descendants stop/resume rendering with the ancestor but never receive
      # their own `Show`/`Hide` otherwise, so their hover/tooltip/pointer-shape
      # cleanup (see `widget_interaction.cr`) is skipped. Propagate down so those
      # handlers run; they're idempotent, so re-emitting is safe.
      emit_descendants Crysterm::Event::Show
    end

    # Hides widget from window
    def hide
      return if !self.state_style.visible?
      # No need to erase the old footprint: `Window#_render` clears the whole
      # cell buffer before each frame, so a hidden widget's old cells are gone
      # on the next render.
      set_visible false
      mark_dirty
      emit Crysterm::Event::Hide
      # See `#show`: descendants must run their own Hide cleanup (tooltip removal,
      # OSC-22 pointer-shape restore) even though only the ancestor was hidden.
      emit_descendants Crysterm::Event::Hide

      window?.try do |s|
        # Rewind focus out of this subtree when it (or a descendant) holds
        # focus: a hidden container must not leave a focused child still
        # receiving keyboard input.
        if (f = s.focused) && (f == self || has_descendant? f)
          s.rewind_focus
        end
      end
    end

    # Sets visibility on the active style and, when CSS has taken over styling
    # (`css_styled?`), also persists it onto the inline `@style`. Otherwise the
    # change would land only on the computed per-state style and be discarded by
    # the next cascade, making the widget reappear/disappear on any restyle.
    private def set_visible(value : Bool) : Nil
      # Write to the *raw* backing style (see `Mixin::Style#state_style`): at the
      # unstyled floor `#style` returns a transient reverse-video `#dup` for a
      # `:focused`/`:selected` widget, so writing visibility through it would be
      # discarded (a focused `Button` could never be hidden).
      self.state_style.visible = value
      persist_inline_style(&.visible=(value))
    end

    # Mirrors a just-applied state-style change onto the inline `@style`, but
    # only when CSS has taken over styling (`css_styled?`) — otherwise the next
    # cascade would discard it. No-op when not CSS-styled. The active-style write
    # itself stays at the call site, since callers deliberately differ on
    # targeting `#style` vs the raw `#state_style` (see `#set_visible` vs
    # `#set_alpha`).
    protected def persist_inline_style(& : ::Crysterm::Style ->) : Nil
      return unless css_styled?
      yield (@style ||= ::Crysterm::Style.new)
    end

    # Toggles widget visibility
    def toggle_visibility
      self.state_style.visible? ? hide : show
    end

    # Returns whether widget is visible. Currently does not check if all parents are also visible.
    def visible?
      self.state_style.visible?
      # Alternative that also checks the full ancestor chain:
      # visible = true
      # self_and_each_ancestor { |a| visible &&= a.style.visible? }
      # visible
    end
  end
end
