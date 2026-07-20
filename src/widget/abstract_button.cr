require "./input"

module Crysterm
  class Widget
    # Abstract base for the button family, modeled after Qt's `QAbstractButton`.
    #
    # Holds the shared `QAbstractButton`-level state — `#text`, `#checkable?`,
    # `#checked?`, `#group` — and the canonical activate/toggle behavior
    # (`#click`/`#toggle`/`#check`/`#uncheck` plus activate-key/click handlers).
    # Push-style buttons inherit this wholesale; marker controls (`CheckBox`,
    # `RadioButton`) override rendering/toggle and wire their own input via
    # `Mixin::CheckMarker`.
    abstract class AbstractButton < Input
      # The button's text label (Qt's `QAbstractButton#text`) — the one label API
      # for the family. The push buttons store it as their `#content`, so `text:`
      # and `content:` can never disagree.
      def text : String
        content
      end

      # :ditto:
      def text=(value : String) : String
        set_content value
        request_render
        value
      end

      # Whether the button keeps a sticky checked state rather than acting as a
      # momentary push button (Qt's `QAbstractButton#checkable`). The marker
      # controls set this true (they are inherently checkable).
      getter? checkable : Bool = false

      # Sets checkability (Qt's `setCheckable`), re-cascading (`:checked` only
      # ever matches a checkable button) and repainting on a real change.
      def checkable=(value : Bool) : Bool
        return value if value == @checkable
        # Uncheck *before* dropping checkability: `#uncheck` is gated on
        # `#checkable?`, and a button left `checked?` while no longer checkable
        # would keep matching `:checked` with no way to clear it.
        uncheck unless value
        @checkable = value
        invalidate_css
        request_render
        value
      end

      # Current toggle state; only meaningful when `#checkable?`
      # (Qt's `QAbstractButton#checked`).
      getter? checked : Bool = false

      # Sets the checked state (Qt's `setChecked`), routing through
      # `#check`/`#uncheck` so the re-cascade, the `Event::StateChanged` emit
      # and the repaint all happen. No-op unless `#checkable?`, hence the honest
      # `#checked?` return.
      def checked=(value : Bool) : Bool
        value ? check : uncheck
        @checked
      end

      # The `ButtonGroup` this button belongs to, or `nil` (Qt's
      # `QAbstractButton#group`). A `RadioButton` grouped by containment under a
      # `Widget::RadioSet` has no `ButtonGroup` and reports `nil`.
      getter group : ::Crysterm::ButtonGroup?

      # :nodoc:
      # Not a user knob: membership is owned by the group, and assigning here
      # would leave the group's own list out of sync.
      setter group

      def initialize(text : String? = nil, checkable : Bool = false, checked : Bool = false, **input)
        super **{keys: true}.merge(input)
        @checkable = checkable
        # `checked: true` without `checkable:` would otherwise create the very
        # state `#checkable=` documents as unclearable: `checked?` true while
        # `#uncheck`/`#toggle` no-op on the `checkable?` guard.
        @checked = checked && checkable

        # `text:` is the family-level spelling of `content:`; assigning it after
        # `super` routes through the subclass's `#text=`.
        text.try { |t| self.text = t }

        # Activate-key wiring is shared by the whole family. `Click` wiring is
        # push-only and stays in the push buttons; the marker controls hit-test
        # the marker glyph via `Mouse` instead.
        handle Crysterm::Event::KeyPress
      end

      # Activates the button (Qt's `QAbstractButton#click`): focuses it (unless
      # `#focus_on_click?` is off), emits `Event::Pressed`, and toggles the checked
      # state when `#checkable?`.
      #
      # A keyboard activation already has focus, so `#focus_on_click?` only gates
      # mouse-click focus theft: a dialog button can opt out (`focus_on_click:
      # false`) so a click doesn't pull focus off a live read and cancel it.
      def click
        focus if focus_on_click?
        emit Crysterm::Event::Pressed
        toggle if checkable?
      end

      # Flips the checked state (only when `#checkable?`) and emits
      # `Event::StateChanged` with the new state.
      def toggle
        return unless checkable?
        @checked = !@checked
        invalidate_css # `checked` attribute selector may now match/unmatch
        emit Crysterm::Event::StateChanged, (@checked ? ::Crysterm::CheckState::Checked : ::Crysterm::CheckState::Unchecked)
        request_render
      end

      # Whether a third, partially-checked (indeterminate) state is currently
      # set. Always false for a plain button; `CheckBox` overrides it, so
      # `#check`/`#uncheck` treat "partial" as a state to settle out of.
      def partial? : Bool
        false
      end

      # Clears any partially-checked state as part of a `#check`/`#uncheck`
      # transition. No-op for a plain button.
      private def clear_partial : Nil
      end

      # Settles `#checked?` to *to*, clearing any partial state and re-cascading.
      private def set_checked(to : Bool) : Nil
        @checked = to
        clear_partial
        invalidate_css
      end

      # Sets the checked state (only when `#checkable?`), emitting
      # `Event::StateChanged` if it changed.
      def check
        return unless checkable?
        return if checked? && !partial? # already settled on checked
        set_checked true
        emit Crysterm::Event::StateChanged, ::Crysterm::CheckState::Checked
        request_render
      end

      # Clears the checked state (only when `#checkable?`), emitting
      # `Event::StateChanged` if it changed. Counterpart to `#check`.
      def uncheck
        return unless checkable?
        return if !checked? && !partial? # already settled on unchecked
        set_checked false
        emit Crysterm::Event::StateChanged, ::Crysterm::CheckState::Unchecked
        request_render
      end

      # Indicates focus via reverse-video at the unstyled floor.
      def floor_focus_reverse? : Bool
        true
      end

      # The keyboard activation gesture, invoked by `#on_keypress` on Space/Enter.
      # A push button `#click`s; the marker controls override it to `#toggle`.
      protected def activate
        click
      end

      def on_keypress(e)
        if e.activates?
          e.accept
          activate
        end
      end

      def on_click(e)
        click
      end

      # Subscribes *block* to this button's activation (`Event::Pressed`) — the
      # block-based spelling of `on(Event::Pressed) { ... }`. Fires on every
      # click/keyboard-activation, checkable or not.
      def on_click(&block) : Nil
        on(::Crysterm::Event::Pressed) { block.call }
      end

      # Subscribes *block* to this button's checked-state changes, handing it the
      # new checked flag. A checkable button emits `Event::StateChanged`
      # (`CheckState`) on toggle; this adapts it to a plain `Bool` (Qt's
      # `toggled(bool)`). Never fires for a non-checkable button.
      def on_toggle(&block : Bool ->) : Nil
        on(::Crysterm::Event::StateChanged) { |e| block.call e.state.checked? }
      end
    end
  end
end
