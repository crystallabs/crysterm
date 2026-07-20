require "./abstract_button"

module Crysterm
  class Widget
    # Button element, modeled after Qt's `QPushButton`.
    #
    # By default it is a momentary push button: activating it (Space/Enter or a
    # click) emits `Event::Pressed`. When `#checkable?` it instead behaves as a
    # toggle button — each activation flips `#checked?` and emits
    # `Event::StateChanged` (in addition to `Event::Pressed`), like a checkable
    # `QPushButton` or a `QToolButton`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![Button screenshot](../../tests/widget/button/button.5s.apng)
    # <!-- /widget-examples:capture -->
    class Button < AbstractButton
      # Whether the button is *flat* — drawn without a frame (Qt's
      # `QPushButton#flat`). Surfaced as the `[flat]` attribute and the `:flat`
      # pseudo-class for CSS.
      getter? flat : Bool = false

      # Whether this is the dialog's *default* button (Qt's
      # `QPushButton#default`). A styling marker only — surfaced as `[default]`
      # for the `:default` pseudo-class; nothing wires a bare Enter to activate it.
      getter? default : Bool = false

      def initialize(checkable : Bool = false, checked : Bool = false, flat : Bool = false, default : Bool = false, **input)
        super **input, checkable: checkable, checked: checked

        @flat = flat
        @default = default

        # A push button additionally activates on a click anywhere on it.
        handle Crysterm::Event::Click
      end

      # Positional text convenience — Qt's `QPushButton(text)`. Routed via
      # `content:` (see `AbstractButton#text`), so `.text`/`.content` both read
      # it back; an explicit `content:` in *opts* wins over the positional
      # *text*.
      def initialize(text : String, **opts)
        initialize(**{content: text}.merge(opts))
      end

      # Toggles the flat (frameless) look, re-cascading so the `[flat]` attribute
      # selector matches/unmatches; marks/unmarks this as the dialog's *default*
      # button (`[default]`).
      css_toggle_setter flat
      css_toggle_setter default
    end
  end
end
