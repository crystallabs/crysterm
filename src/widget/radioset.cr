module Crysterm
  class Widget
    # Radio set element
    #
    # <!-- widget-examples:capture v1 -->
    # ![RadioSet screenshot](../../tests/widget/radioset/radioset.5s.apng)
    # <!-- /widget-examples:capture -->
    class RadioSet < Box
      # The selected radio in this set, or `nil`. Members are the set's
      # descendant `RadioButton`s; other checkables are skipped.
      def checked_button : RadioButton?
        each_descendant do |el|
          return el if el.is_a?(RadioButton) && el.checked?
        end
        nil
      end
    end
  end
end
