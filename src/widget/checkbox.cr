require "./node"
require "./element"
require "./input"

module Crysterm
  # Checkbox element
  class Checkbox < Input
    include EventHandler

    getter value = false

    def initialize(value = false, **element)
      super **element

      @text = element["content"]? || ""
      @value = value

      # on(KeyPressEvent) do |key|
      #  if key.name==Enter || Space
      #    toggle
      #    @screen.render
      #  end
      # end

      # TODO - why conditional? could be cool to trigger clicks by
      # events even if mouse is disabled.
      # if mouse
      on(ClickEvent) do
        toggle
        @screen.render
      end
      # end

      on(FocusEvent) do
        lpos = @lpos
        next if !lpos
        @screen.application.tput.lsave_cursor "checkbox"
        # XXX can this be a tput call? or needs more logic in crysterm?
        @screen.application.tput.cup lpos.yi, lpos.xi + 1
        @screen.application.tput.show_cursor
      end

      on(BlurEvent) do
        @screen.application.tput.lrestore_cursor "checkbox", true
      end
    end

    def render
      clear_pos true
      set_content ("[" + (@value ? 'x' : ' ') + "] " + @text), true
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
      @value ? uncheck : check
    end
  end
end
