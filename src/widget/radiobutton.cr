require "./radioset"

module Crysterm
  class Widget
    # Radio button element
    #
    # <!-- widget-examples:capture v1 -->
    # ![RadioButton screenshot](../../examples/widget/radiobutton/radiobutton-capture.png)
    # <!-- /widget-examples:capture -->
    class RadioButton < Checkbox
      include EventHandler

      # TODO option for changing icons

      # Add support for real toggling instead of unchecking
      # other elements. So that one can even make a widget
      # where only 1 is unchecked, the rest are all checked.

      # getter value = false

      # def initialize(value = false, **element)
      def initialize(**checkbox)
        super **checkbox

        handle Crysterm::Event::Check
      end

      # A radio button only ever *checks* itself when toggled; the containing
      # group unchecks the others (see `#on_check`). Without this override it
      # would inherit `Checkbox#toggle` (`checked? ? uncheck : check`), so
      # pressing Space/Enter on the selected radio would uncheck it and leave
      # the group with nothing selected.
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

        el.try &.each_descendant do |cel|
          # TODO
          # next if !(cel.is_a? RadioButton) || cel == self
          # cel.toggle if cel.is_a?(RadioButton) && cel != self
          cel.uncheck if cel.is_a?(RadioButton) && cel != self
        end
        # TODO
        # el.try &.children.each do |cel|
        #  # next if !(cel.is_a? RadioButton) || cel == self
        #  cel.uncheck if cel.is_a?(RadioButton) && cel != self
        # end
      end
    end
  end
end
