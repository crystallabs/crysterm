require "./abstract_button"
require "../mixin/check_marker"
require "../mixin/exclusive_group"
require "./radioset"

module Crysterm
  class Widget
    # Radio button element, modeled after Qt's `QRadioButton`.
    #
    # Derives `AbstractButton` directly — a sibling of `CheckBox`, as Qt makes
    # `QRadioButton` a sibling of `QCheckBox` under `QAbstractButton` (rather
    # than `QRadioButton < QCheckBox`). Marker rendering and input wiring shared
    # with `CheckBox` come from `Mixin::CheckMarker`; this class adds group
    # exclusivity (`#on_check`) and the check-only `#toggle`.
    #
    # <!-- widget-examples:capture v1 -->
    # ![RadioButton screenshot](../../tests/widget/radiobutton/radiobutton.5s.apng)
    # <!-- /widget-examples:capture -->
    class RadioButton < AbstractButton
      include Mixin::CheckMarker
      include Mixin::ExclusiveGroup

      # TODO option for changing icons

      # Add support for real toggling instead of unchecking
      # other elements. So that one can even make a widget
      # where only 1 is unchecked, the rest are all checked.

      def initialize(checked : Bool = false, **input)
        super **input

        setup_marker_control checked, input["content"]?
        handle Crysterm::Event::Check
      end

      # A radio button only ever *checks* itself when toggled; the containing
      # group unchecks the others (see `#on_check`). Without this override it
      # inherits `AbstractButton#toggle` (flips checked/unchecked), so
      # Space/Enter on the selected radio would uncheck it, leaving the group
      # with nothing selected.
      def toggle
        check
      end

      def render
        set_content selectable_content('(', ')', checked? ? '*' : ' '), true
        super false
      end

      def on_check(e)
        el = self
        while el && (el = el.parent)
          if el.is_a?(RadioSet) # || el.is_a?(Form)
            break
          end
        end
        el = el || parent

        # Uncheck the sibling radios (only radios — a `RadioSet` may hold other
        # checkables that this exclusivity must not touch). The shared decision
        # ("different, currently-checked → uncheck") lives in `ExclusiveGroup`.
        el.try &.each_descendant do |cel|
          exclude_peer cel, self if cel.is_a?(RadioButton)
        end
      end
    end
  end
end
