require "./abstract_button"
require "../mixin/check_marker"
require "../mixin/exclusive_group"
require "./radioset"

module Crysterm
  class Widget
    # Radio button element, modeled after Qt's `QRadioButton`.
    #
    # Marker rendering and input wiring come from `Mixin::CheckMarker`; this
    # class adds group exclusivity (`#on_statechanged`) and the check-only `#toggle`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![RadioButton screenshot](../../tests/widget/radiobutton/radiobutton.5s.apng)
    # <!-- /widget-examples:capture -->
    class RadioButton < AbstractButton
      include Mixin::CheckMarker
      include Mixin::ExclusiveGroup

      # TODO: option for changing icons.
      # TODO: support real toggling, so a set can have exactly one *unchecked*
      # member rather than exactly one checked.

      def initialize(checked : Bool = false, **input)
        super **input

        setup_marker_control checked, input["content"]?
        handle Crysterm::Event::StateChanged
      end

      # A radio button only ever *checks* itself when toggled; the containing
      # group unchecks the others. Overrides `AbstractButton#toggle`, which would
      # let Space/Enter uncheck the selection and leave the group empty.
      def toggle
        check
      end

      def render
        # `(`/`)` and the state mark resolve CSS-first (`RadioButton::indicator`,
        # `:checked` addressing the checked mark), then the registry.
        set_content marker_line(Glyphs::Role::RadioOpen, Glyphs::Role::RadioClose,
          checked? ? Glyphs::Role::RadioChecked : Glyphs::Role::RadioUnchecked,
          Glyphs::Role::RadioChecked, Glyphs::Role::RadioUnchecked), true
        super false
      end

      def on_statechanged(e)
        # Only a transition *into* checked drives exclusivity; ignore uncheck and
        # partial transitions the merged `StateChanged` now also reports.
        return unless e.state.checked?
        # A `ButtonGroup` member defers exclusivity to the group (its own
        # `exclude_peers` already handles it, regardless of layout) — matching
        # Qt, where per-parent autoExclusive applies only to ungrouped buttons.
        return if group
        el = self
        while el && (el = el.parent)
          if el.is_a?(RadioSet) # || el.is_a?(Form)
            break
          end
        end
        el = el || parent

        # Uncheck the sibling radios — only radios, as a `RadioSet` may hold
        # other checkables that this exclusivity must not touch.
        el.try &.each_descendant do |cel|
          exclude_peer cel, self if cel.is_a?(RadioButton)
        end
      end
    end
  end
end
