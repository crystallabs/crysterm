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
      end

      # Activates the button: focuses it, emits `Event::Press`, and toggles the
      # checked state when `#checkable?`.
      def press
        focus
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

      # Sets the checked state (only when `#checkable?`), emitting `Event::Check`
      # if it changed. Lets a checkable button be driven through the same
      # interface as `CheckBox` (e.g. by `ButtonGroup`).
      def check
        return unless checkable?
        return if checked?
        @checked = true
        @value = true # `#value` mirrors `#checked?` for a checkable control
        invalidate_css
        emit Crysterm::Event::Check, @checked
        request_render
      end

      # Clears the checked state (only when `#checkable?`), emitting
      # `Event::UnCheck` if it changed. Counterpart to `#check`.
      def uncheck
        return unless checkable?
        return unless checked?
        @checked = false
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

      def on_keypress(e)
        if e.activates?
          e.accept
          press
        end
      end

      def on_click(e)
        press
      end
    end
  end
end
