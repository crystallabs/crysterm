require "./node"
require "./element"
require "./input"

module Crysterm
  module Widget
    # Checkbox element
    class Checkbox < Input
      include EventHandler

      # TODO support for changing icons

      # TODO potentially, turn toggle() into toggle_value() which
      # does just that, and toggle_checked() which does what toggle()
      # currently does and also calls render.

      property? checked : Bool = false
      property value : Bool = false
      property text : String = ""

      def initialize(checked : Bool = false, value : Bool? = nil, **input)
        super **input

        @checked = checked

        @value = value.nil? ? checked : value

        input["content"]?.try do |c|
          @text = c
        end

        on(KeyPressEvent) do |e|
          #if e.key == Tput::Key::Enter || e.key == Tput::Key::Space
          if e.key == Tput::Key::Enter || e.char == ' '
            e.accept!
            toggle
            @screen.render
          end
        end

        # TODO - why conditional? could be cool to trigger clicks by
        # events even if mouse is disabled.
        # if mouse
          on(ClickEvent) do
            toggle
            @screen.render
          end
        # end

        on(FocusEvent) do
          next unless lpos = @lpos
          @screen.application.tput.lsave_cursor "checkbox"
          @screen.application.tput.cursor_pos lpos.yi, lpos.xi + 1
          @screen.application.tput.show_cursor
        end

        on(BlurEvent) do
          @screen.application.tput.lrestore_cursor "checkbox", true
        end
      end

      def render
        clear_pos true
        set_content ("[" + (checked? ? 'x' : ' ') + "] " + @text), true
        super false
      end

      def check
        return if checked?
        @checked = true
        @value = !@value
        emit CheckEvent, @value
      end

      def uncheck
        return unless checked?
        @checked = false
        @value = !@value
        emit UnCheckEvent, @value
      end

      def toggle
        checked? ? uncheck : check
      end
    end
  end
end
