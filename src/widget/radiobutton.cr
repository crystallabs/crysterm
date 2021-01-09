require "./radioset"

module Crysterm
  # Radio button element
  class RadioButton < Checkbox
    include EventHandler

    getter value = false

    def initialize(value=false, **element)
      super **element
      @text = element["content"]? || ""
      @value = value

      on(CheckEvent) do
        el = self
        while el && (el = el.parent)
          if el.is_a?(RadioSet) || el.is_a?(Form)
            break
          end
          el = el || parent

          el.try &.children.each do |cel|
            next if !(cel.is_a? RadioButton) || cel == self
            cel.uncheck if cel.is_a? RadioButton
          end
        end
      end
    end

    def render
      clear_pos true
      set_content ("(" + (@value ? '*' : ' ') + ") " + @text), true
      super
    end

    def check
      return if @value
      @value = true
      emit CheckEvent
    end

    def uncheck
      return unless @value
      @value = false
      emit UnCheckEvent
    end

    def toggle
      check
    end
  end
end
