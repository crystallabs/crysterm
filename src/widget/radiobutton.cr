require "./radioset"

module Crysterm
  class Widget
    # Radio button element
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

        on Crysterm::Event::Check, ->on_check(Crysterm::Event::Check)
      end

      def render
        clear_last_rendered_position true
        set_content ("(" + (@value ? '*' : ' ') + ") " + @text), true
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
          # next if !(cel.is_a? RadioButton) || cel == self
          # cel.toggle if cel.is_a?(RadioButton) && cel != self
          cel.uncheck if cel.is_a?(RadioButton) && cel != self
        end
        # el.try &.children.each do |cel|
        #  # next if !(cel.is_a? RadioButton) || cel == self
        #  cel.uncheck if cel.is_a?(RadioButton) && cel != self
        # end
      end
    end
  end
end
