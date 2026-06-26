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
    # ![Button screenshot](../../examples/widget/button/button-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Button < AbstractButton
      # Whether the button is *flat* — drawn without a frame (Qt's
      # `QPushButton#flat`). Surfaced as the `[flat]` attribute so author/theme
      # CSS can target it (the theme strips the border via `Button[flat]`); also
      # the target of Qt's `:flat` pseudo-class (see `CSS::Qss`).
      getter? flat : Bool = false

      # Whether this is the dialog's *default* button — the one a bare Enter
      # activates (Qt's `QPushButton#default`). Surfaced as `[default]` for the
      # `:default` pseudo-class, so it can be emphasized via CSS.
      getter? default : Bool = false

      def initialize(checkable : Bool = false, checked : Bool = false, flat : Bool = false, default : Bool = false, **input)
        super **input

        @checkable = checkable
        @checked = checked
        @flat = flat
        @default = default

        handle Crysterm::Event::KeyPress
        handle Crysterm::Event::Click
      end

      # Toggles the flat (frameless) look, re-cascading so the `[flat]` attribute
      # selector matches/unmatches.
      def flat=(value : Bool) : Bool
        return value if value == @flat
        @flat = value
        invalidate_css
        request_render
        value
      end

      # Marks/unmarks this as the dialog's default button (`[default]`).
      def default=(value : Bool) : Bool
        return value if value == @default
        @default = value
        invalidate_css
        request_render
        value
      end
    end
  end
end
