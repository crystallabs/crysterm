require "./abstract_interactive"

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
    abstract class AbstractButton < AbstractInteractive
      # The button's text label (Qt's `QAbstractButton#text`) — the one label API
      # for the family. `#text` and `#content` can never disagree, on any
      # button: the push buttons store the label as their `#content`, and the
      # marker controls (`CheckBox`/`RadioButton`) route both accessors to the
      # bare label — the composed `"[x] Label"` line their paint draws is
      # render-internal (reported by `#rendered_content`, never the property
      # value).
      def text : String
        content
      end

      # :ditto:
      def text=(value : String) : String
        set_content value
        update!
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
        update!
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

      # The `styles.checked` slot (and CSS `[checked]`) applies while actually
      # checked.
      def style_checked? : Bool
        checkable? && checked?
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

        # The held-down (pressed) gesture is family-wide: any button shows its
        # `:pressed` look while the primary mouse button is held on it.
        on Crysterm::Event::Mouse, ->handle_press_mouse(Crysterm::Event::Mouse)
      end

      # Whether the button is currently held down by a press gesture (Qt's
      # `QAbstractButton#isDown`). While down the widget takes
      # `WidgetState::Selected`, so `:pressed`/`:active` CSS rules — pressed
      # colors, a `top`/`left` press-in nudge, a dropped `box-shadow` — apply.
      getter? down : Bool = false

      # Sets the held-down state (Qt's `setDown`): shows or clears the pressed
      # look without emitting click/toggle events. Driven by the mouse
      # press/release gesture and the keyboard-activation flash; callable
      # directly to present a button as pressed programmatically.
      def down=(value : Bool) : Bool
        return value if @down == value
        @down = value
        if value
          self.state = :selected
        elsif state.selected?
          # Restore only what the press styling set — a state changed under the
          # press (e.g. a disable) stands. An unfocused button still under the
          # pointer falls back to `:hover`.
          self.state = focused? ? WidgetState::Focused : (under_mouse? ? WidgetState::Hovered : WidgetState::Normal)
        end
        value
      end

      # The press-gesture driver: primary-button press enters the held-down
      # look and grabs the mouse (so the release is seen even off-widget);
      # release clears it. Deliberately never `accept`s — the window's default
      # handling (click-to-focus, `Event::Click` synthesis) must still run.
      def handle_press_mouse(e)
        if e.action.down? && primary_press_button?(e.button)
          self.down = true
          grab_mouse
        elsif e.action.up? && down? && primary_press_button?(e.button)
          self.down = false
        end
      end

      # Whether *button* is the press gesture's button: the left button, or
      # `None` for terminals whose release/legacy reports carry no button.
      private def primary_press_button?(button : ::Tput::Mouse::Button) : Bool
        button.left? || button.none?
      end

      # Pending un-press of a keyboard-activation flash, so a re-activation
      # extends the flash instead of being cut short by the earlier timer.
      @press_flash : ::Crysterm::Timer?

      # Shows the pressed look briefly around a keyboard activation (the visual
      # of Qt's `animateClick`): terminals deliver no key-release, so the
      # held-down phase is simulated with a short timer. Skipped under
      # `render.reduced_motion`.
      private def animate_press : Nil
        return if ::Crysterm::Config.render_reduced_motion
        @press_flash.try &.stop
        self.down = true
        @press_flash = ::Crysterm::Timer.single_shot(0.1.seconds) { self.down = false }
      end

      # Activates the button (Qt's `QAbstractButton#click`): focuses it (unless
      # `#focus_on_click?` is off), emits `Event::Clicked`, and toggles the checked
      # state when `#checkable?`.
      #
      # A keyboard activation already has focus, so `#focus_on_click?` only gates
      # mouse-click focus theft: a dialog button can opt out (`focus_on_click:
      # false`) so a click doesn't pull focus off a live read and cancel it.
      def click
        focus if focus_on_click?
        emit Crysterm::Event::Clicked
        toggle if checkable?
      end

      # Flips the checked state (only when `#checkable?`) and emits
      # `Event::StateChanged` with the new state.
      def toggle
        return unless checkable?
        @checked = !@checked
        # `#style` resolves through the checked state (the `styles.checked`
        # slot), so the frame-memoized resolution is stale as of this flip.
        invalidate_frame_style
        invalidate_css # `checked` attribute selector may now match/unmatch
        emit Crysterm::Event::StateChanged, (@checked ? ::Crysterm::CheckState::Checked : ::Crysterm::CheckState::Unchecked)
        # Plain-`Bool` counterpart of `StateChanged` ↔ Qt's `toggled(bool)`; both
        # fire (Qt likewise emits `toggled` and `stateChanged`), so a listener may
        # take whichever payload it wants. `#on_toggle` adapts `StateChanged`.
        emit Crysterm::Event::Toggled, @checked
        update!
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
        # `#style` resolves through the checked state (the `styles.checked`
        # slot), so the frame-memoized resolution is stale as of this flip.
        invalidate_frame_style
        invalidate_css
      end

      # Settles `#checked?` to *to* (only when `#checkable?`), emitting
      # `Event::StateChanged`/`Event::Toggled` if it changed. Shared body of
      # `#check`/`#uncheck`, which differ only in polarity.
      private def settle_checked(to : Bool) : Nil
        return unless checkable?
        return if checked? == to && !partial? # already settled on `to`
        set_checked to
        emit Crysterm::Event::StateChanged, (to ? ::Crysterm::CheckState::Checked : ::Crysterm::CheckState::Unchecked)
        emit Crysterm::Event::Toggled, to
        update!
      end

      # Sets the checked state (only when `#checkable?`), emitting
      # `Event::StateChanged` if it changed.
      def check
        settle_checked true
      end

      # Clears the checked state (only when `#checkable?`), emitting
      # `Event::StateChanged` if it changed. Counterpart to `#check`.
      def uncheck
        settle_checked false
      end

      # Indicates focus via reverse-video at the unstyled floor.
      def floor_focus_reverse? : Bool
        true
      end

      # The keyboard activation gesture, invoked by `#handle_key_press` on Space/Enter.
      # A push button flashes its pressed look and `#click`s; the marker
      # controls override it to `#toggle`.
      protected def activate
        animate_press
        click
      end

      def handle_key_press(e)
        if e.activates?
          e.accept
          activate
        end
      end

      # The mouse-click slot the push buttons wire up (`Widget::Button`/
      # `ToolButton` subscribe it to `Event::Click`). Named `handle_*`, not
      # `on_*`: `on_click` below is the *subscription* API, and an overload
      # pair whose members mean "handle it" vs "connect to it" is one arity
      # away from a subclass clobbering the wrong one.
      def handle_click(e)
        click
      end

      # Subscribes *block* to this button's activation (`Event::Clicked`) — the
      # block-based spelling of `on(Event::Clicked) { ... }`; returns the
      # `Subscription` so the caller can disconnect. Fires on every
      # click/keyboard-activation, checkable or not.
      def on_clicked(&block) : ::EventHandler::Subscription
        on(::Crysterm::Event::Clicked) { block.call }
      end

      # :ditto: — shorter spelling, kept as an alias of the canonical
      # `#on_clicked` (sugar names mirror their event names).
      def on_click(&block) : ::EventHandler::Subscription
        on_clicked(&block)
      end

      # Subscribes *block* to this button's checked-state changes, handing it the
      # new checked flag; returns the `Subscription` so the caller can
      # disconnect. A checkable button emits `Event::StateChanged`
      # (`CheckState`) on toggle; this adapts it to a plain `Bool` (Qt's
      # `toggled(bool)`). Never fires for a non-checkable button.
      def on_toggled(&block : Bool ->) : ::EventHandler::Subscription
        on(::Crysterm::Event::StateChanged) { |e| block.call e.state.checked? }
      end

      # :ditto: — present-tense spelling, kept as an alias of the past-tense
      # canonical (sugar names mirror their event names).
      def on_toggle(&block : Bool ->) : ::EventHandler::Subscription
        on_toggled(&block)
      end
    end
  end
end
