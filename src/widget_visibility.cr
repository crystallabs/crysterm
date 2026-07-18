module Crysterm
  class Widget
    # Shows widget on window
    def show
      return if self.state_style.visible?
      set_visible true
      mark_dirty
      emit Crysterm::Event::Show
      # Descendants stop/resume rendering with the ancestor but get no `Show`/
      # `Hide` of their own, skipping their hover/tooltip/pointer-shape cleanup.
      # Propagate down so those handlers run; they're idempotent.
      emit_descendants Crysterm::Event::Show
    end

    # Hides widget from window
    def hide
      return if !self.state_style.visible?
      # No need to erase the old footprint: the whole cell buffer is cleared
      # before each frame, so a hidden widget's old cells are gone next render.
      set_visible false
      mark_dirty
      emit Crysterm::Event::Hide
      # As in `#show`: descendants must run their own Hide cleanup (tooltip
      # removal, OSC-22 pointer-shape restore) even though only we were hidden.
      emit_descendants Crysterm::Event::Hide

      window?.try do |s|
        # Rewind focus out of this subtree when it (or a descendant) holds
        # focus: a hidden container must not leave a focused child still
        # receiving keyboard input.
        if (f = s.focused) && (f == self || ancestor_of? f)
          s.rewind_focus
        end
      end
    end

    # Sets visibility on the active style and, when CSS has taken over styling
    # (`css_styled?`), also persists it onto the inline `@style`. Otherwise the
    # change would land only on the computed per-state style and be discarded by
    # the next cascade, making the widget reappear/disappear on any restyle.
    private def set_visible(value : Bool) : Nil
      # Write to the *raw* backing style: at the unstyled floor `#style` returns a
      # transient reverse-video `#dup` for a `:focused`/`:selected` widget, so a
      # write through it would be discarded (a focused `Button` could never hide).
      self.state_style.visible = value
      # Visibility is a widget-level property, not a per-state visual, but a
      # CSS-styled widget has a distinct computed style per materialized state and
      # `state_style` touches only the current one. Apply across every state, or a
      # widget that later changes state resurrects its stale per-state visibility.
      @styles.visible = value
      persist_inline_style(&.visible=(value))
    end

    # Mirrors a just-applied state-style change onto the inline `@style`, but only
    # when CSS has taken over styling (`css_styled?`) — otherwise the next cascade
    # would discard it. The active-style write stays at the call site: callers
    # deliberately differ on targeting `#style` vs the raw `#state_style`.
    #
    # A widget under *active* CSS that matches no rule ends `css_styled? == false`,
    # yet every restyle still resets it to a fresh dup of its pristine snapshot,
    # so the change must land on that snapshot too or the next cascade silently
    # undoes it (a hidden widget reappears; a faded one snaps back to full opacity).
    # Widgets no cascade ever touched have no snapshot — no-op for them.
    protected def persist_inline_style(& : ::Crysterm::Style ->) : Nil
      if css_styled?
        yield (@style ||= ::Crysterm::Style.new)
      elsif base = css_base_normal_if_captured
        yield base
      end
    end

    # Shows or hides the widget (Qt's `QWidget#setVisible`). Routes through
    # `#show`/`#hide` so their events and focus rewind run.
    def visible=(value : Bool) : Bool
      value ? show : hide
      value
    end

    # Returns whether widget is visible. Does not check whether the ancestors are
    # visible too; see `#visible_in_tree?`.
    def visible?
      self.state_style.visible?
    end

    # Inverse of `#visible?` (Qt's `QWidget#isHidden`). Consults only this
    # widget's own flag; see `#visible_in_tree?` for the ancestor-aware answer.
    def hidden? : Bool
      !visible?
    end

    # Returns whether this widget *and every ancestor* is visible, walking the
    # whole parent chain. Standalone `Rendered` listeners (the media overlays)
    # must use this before resolving rendered coordinates: hiding an ancestor
    # clears only that node's flag, leaving a descendant `visible?`, but the
    # hidden ancestor has no rendered position and `coords(true)` would raise.
    def visible_in_tree? : Bool
      anc = self
      while anc
        return false unless anc.visible?
        anc = anc.parent
      end
      true
    end
  end
end
