require "./input"

module Crysterm
  class Widget
    # Abstract base for the button family, modeled after Qt's `QAbstractButton`.
    #
    # `Button` (push/checkable), `ToolButton`, `CheckBox` and `RadioButton` all
    # derive this directly as siblings, matching Qt's
    # `QPushButton`/`QToolButton`/`QCheckBox`/`QRadioButton` under
    # `QAbstractButton` (rather than chaining `QToolButton` off `QPushButton` or
    # `QRadioButton` off `QCheckBox`, as Crysterm previously did).
    #
    # Holds the shared `QAbstractButton`-level state — `#text`, `#checkable?`,
    # `#checked?`, `#value` — and the canonical push/toggle behavior
    # (`#press`/`#toggle`/`#check`/`#uncheck` plus activate-key/click handlers).
    # Push-style buttons (`Button`, `ToolButton`) inherit this wholesale; marker
    # controls (`CheckBox`, `RadioButton`) override rendering/toggle and wire
    # their own input via `Mixin::CheckMarker`.
    abstract class AbstractButton < Input
      # The button's text label (Qt's `QAbstractButton#text`). The marker controls
      # render it after their `[x]`/`(*)` glyph; the push buttons use `#content`.
      property text : String = ""

      # Last activation value: momentarily true during a push `#press`, and the
      # mirror of `#checked?` for the checkable controls.
      property value : Bool = false

      # Whether the button keeps a sticky checked state rather than acting as a
      # momentary push button (Qt's `QAbstractButton#checkable`). The marker
      # controls set this true (they are inherently checkable).
      property? checkable : Bool = false

      # Current toggle state; only meaningful when `#checkable?`
      # (Qt's `QAbstractButton#checked`).
      property? checked : Bool = false

      def initialize(checkable : Bool = false, checked : Bool = false, **input)
        super **input
        @checkable = checkable
        @checked = checked

        # Activate-key wiring is shared by the whole family (push buttons and the
        # marker controls both activate on Space/Enter), so it lives here rather
        # than in each subclass — a subclass can no longer be silently dead to
        # the keyboard by forgetting it. The `Click` wiring is push-only and
        # stays in `Button`/`ToolButton` (the marker controls hit-test the marker
        # glyph via `Mouse` instead — see `Mixin::CheckMarker`).
        handle Crysterm::Event::KeyPress
      end

      # Activates the button: focuses it (unless `#focus_on_click?` is off),
      # emits `Event::Press`, and toggles the checked state when `#checkable?`.
      #
      # A keyboard press already has focus, so gating on `#focus_on_click?` only
      # suppresses mouse-click focus theft — letting a dialog button opt out
      # (`focus_on_click: false`) so a click doesn't pull focus off a live read
      # (e.g. a `Prompt`'s `LineEdit`), which would end the read as a cancel.
      def press
        focus if focus_on_click?
        @value = true
        emit Crysterm::Event::Press
        @value = false

        toggle if checkable?
      end

      # Flips the checked state (only when `#checkable?`) and emits the matching
      # `Event::Check`/`Event::UnCheck`.
      def toggle
        return unless checkable?
        @checked = !@checked
        @value = @checked # `#value` mirrors `#checked?` for a checkable control
        invalidate_css    # `checked` attribute selector may now match/unmatch
        if @checked
          emit Crysterm::Event::Check, @checked
        else
          emit Crysterm::Event::UnCheck, @checked
        end
        request_render
      end

      # Whether a third, partially-checked (indeterminate) state is currently
      # set. Always false for a plain button; `CheckBox` overrides it (via its
      # `#tristate?` support) so `#check`/`#uncheck` here treat "partial" as a
      # state that a transition must settle out of.
      def partial? : Bool
        false
      end

      # Clears any partially-checked state as part of a `#check`/`#uncheck`
      # transition. No-op for a plain button; `CheckBox` overrides it to reset
      # its `@partial` flag, letting the transition body below live once.
      private def clear_partial : Nil
      end

      # Sets the checked state (only when `#checkable?`), emitting `Event::Check`
      # if it changed. Lets a checkable button be driven through the same
      # interface as `CheckBox` (e.g. by `ButtonGroup`).
      def check
        return unless checkable?
        return if checked? && !partial? # already settled on checked
        @checked = true
        clear_partial
        @value = true # `#value` mirrors `#checked?` for a checkable control
        invalidate_css
        emit Crysterm::Event::Check, @checked
        request_render
      end

      # Clears the checked state (only when `#checkable?`), emitting
      # `Event::UnCheck` if it changed. Counterpart to `#check`.
      def uncheck
        return unless checkable?
        return if !checked? && !partial? # already settled on unchecked
        @checked = false
        clear_partial
        @value = false # `#value` mirrors `#checked?` for a checkable control
        invalidate_css
        emit Crysterm::Event::UnCheck, @checked
        request_render
      end

      # Button-family controls indicate focus via reverse-video at the unstyled
      # floor (see `Mixin::Style#floor_focus_reverse?`) — inverting a small,
      # mostly single-line control is the clearest no-color focus cue, unlike a
      # large container/editor, which this hook leaves alone.
      def floor_focus_reverse? : Bool
        true
      end

      # The keyboard activation gesture, invoked by `#on_keypress` on Space/Enter.
      # A push button `#press`es; the marker controls (`CheckBox`/`RadioButton`)
      # override this via `Mixin::CheckMarker` to `#toggle` instead, so one
      # `#on_keypress` serves the whole family.
      protected def activate
        press
      end

      def on_keypress(e)
        if e.activates?
          e.accept
          activate
        end
      end

      def on_click(e)
        press
      end
    end
  end
end
