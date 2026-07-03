require "./abstract_button"

module Crysterm
  class Widget
    # Button element, modeled after Qt's `QPushButton`.
    #
    # By default it is a momentary push button: activating it (Space/Enter or a
    # click) emits `Event::Press`. When `#checkable?` it instead behaves as a
    # toggle button — each activation flips `#checked?` and emits `Event::Check`
    # or `Event::UnCheck` (in addition to `Event::Press`), like a checkable
    # `QPushButton` or a `QToolButton`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Button screenshot](../../tests/widget/button/button.5s.apng)
    # <!-- /widget-examples:capture -->
    class Button < AbstractButton
      # Whether the button is *flat* — drawn without a frame (Qt's
      # `QPushButton#flat`). Surfaced as the `[flat]` attribute so theme CSS can
      # target it (theme strips the border via `Button[flat]`); also the target
      # of Qt's `:flat` pseudo-class (see `CSS::Qss`).
      getter? flat : Bool = false

      # Whether this is the dialog's *default* button (Qt's
      # `QPushButton#default`). This is a styling marker only: it is surfaced as
      # `[default]` for the `:default` pseudo-class so theme CSS can highlight
      # it, but nothing currently wires a bare Enter to activate it.
      getter? default : Bool = false

      def initialize(checkable : Bool = false, checked : Bool = false, flat : Bool = false, default : Bool = false, **input)
        super **input, checkable: checkable, checked: checked

        @flat = flat
        @default = default

        # Activate-key wiring is inherited from `AbstractButton`; a push button
        # additionally activates on a click anywhere on it.
        handle Crysterm::Event::Click
      end

      # Toggles the flat (frameless) look, re-cascading so the `[flat]` attribute
      # selector matches/unmatches; marks/unmarks this as the dialog's *default*
      # button (`[default]`).
      css_toggle_setter flat
      css_toggle_setter default
    end
  end
end
