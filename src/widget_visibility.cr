module Crysterm
  class Widget
    # Shows widget on window
    def show
      return if state_style.visible?
      set_visible true
      update
      emit Crysterm::Event::Show
      # Descendants stop/resume rendering with the ancestor but get no `Show`/
      # `Hide` of their own, skipping their hover/tooltip/pointer-shape cleanup.
      # Propagate down so those handlers run; they're idempotent.
      emit_descendants Crysterm::Event::Show
    end

    # Hides widget from window
    def hide
      return if !state_style.visible?
      # No need to erase the old footprint: the whole cell buffer is cleared
      # before each frame, so a hidden widget's old cells are gone next render.
      set_visible false
      update
      emit Crysterm::Event::Hide
      # As in `#show`: descendants must run their own Hide cleanup (tooltip
      # removal, OSC-22 pointer-shape restore) even though only we were hidden.
      emit_descendants Crysterm::Event::Hide

      window?.try do |s|
        # Rewind focus out of this subtree when it (or a descendant) holds
        # focus: a hidden container must not leave a focused child still
        # receiving keyboard input.
        if (f = s.focused) && covers?(f)
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
      state_style.visible = value
      # Visibility is a widget-level property, not a per-state visual, but a
      # CSS-styled widget has a distinct computed style per materialized state and
      # `state_style` touches only the current one. Apply across every state, or a
      # widget that later changes state resurrects its stale per-state visibility.
      @styles.visible = value
      persist_inline_style(&.visible=(value))
      # Visibility decides whether the hit test descends into this widget, and
      # the flip needs no render, so the window's hover memo (keyed on the frame
      # counter) would otherwise keep answering with a widget that is now hidden
      # — or keep missing one that is now shown — for the rest of the frame.
      window?.try &.invalidate_hit_memo
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
    #
    # Qt mapping: this is `isVisibleTo(parentWidget())` — the widget's own flag.
    # Qt's plain `isVisible()` (ancestor-aware) is `#visible_in_tree?`; porters
    # reaching for `visible?` usually want that one.
    def visible?
      state_style.visible?
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
    # hidden ancestor has no rendered position and `coords(rendered: true)` would raise.
    def visible_in_tree? : Bool
      anc = self
      while anc
        return false unless anc.visible?
        anc = anc.parent
      end
      true
    end

    # A checkable `Action` that shows and hides this widget, its check
    # following the widget's visibility — Qt's `QDockWidget::toggleViewAction`
    # for any widget, so a View menu lists the panes of a layout with one
    # entry each. Created on the first call, with *text* (the widget's
    # `#label` by default); the same action on every later call, *text*
    # ignored. Triggering it calls `#show` or `#hide`; a `#show`/`#hide` from
    # anywhere else re-checks it (through `Event::Show`/`Event::Hide`), so
    # the entry never disagrees with the widget. An app refusing a hide (the
    # last pane of a layout) disables the action, as it would any entry.
    def toggle_view_action(text : String? = nil) : Action
      @toggle_view_action ||= begin
        action = Action.new(text || label || "", checkable: true)
        action.on(Crysterm::Event::Triggered) { |e| e.checked ? show : hide }
        # The check follows the widget (`Action#bind_checked`): set now, and
        # again on every show or hide.
        action.bind_checked(self, Crysterm::Event::Show) { visible? }
        action.bind_checked(self, Crysterm::Event::Hide) { visible? }
        action
      end
    end

    @toggle_view_action : Action?
  end
end
