module Crysterm
  class Widget
    # Radio set element
    #
    # <!-- widget-examples:capture v1 -->
    # ![RadioSet screenshot](../../tests/widget/radioset/radioset.5s.apng)
    # <!-- /widget-examples:capture -->
    class RadioSet < Box
      # TODO: possibly inherit parent's style.
      # @style = @parent.style

      # The selected radio in this set, or `nil` — the containment-grouped
      # counterpart of `ButtonGroup#checked_button` (a `RadioSet`'s members are
      # its descendant `RadioButton`s, not an explicit list, so there is no
      # `ButtonGroup` and `AbstractButton#group` reports `nil` for them).
      #
      # Non-radio checkables under the set are not members and are skipped, the
      # same rule `RadioButton#on_check` enforces when unchecking siblings.
      def checked_button : RadioButton?
        each_descendant do |el|
          return el if el.is_a?(RadioButton) && el.checked?
        end
        nil
      end
    end
  end
end
