require "./input"

module Crysterm
  class Widget
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

        on(Crysterm::Event::KeyPress) do |e|
          # if e.key == Tput::Key::Enter || e.key == Tput::Key::Space
          if e.key == Tput::Key::Enter || e.char == ' '
            e.accept!
            toggle
            @window.render
          end
        end

        on(Crysterm::Event::Click) do
          toggle
          @window.render
        end
        # end

        on(Crysterm::Event::Focus) do
          next unless lpos = @lpos
          @window.display.tput.lsave_cursor :checkbox
          @window.display.tput.cursor_pos lpos.yi, lpos.xi + 1
          @window.display.tput.show_cursor
        end

        on(Crysterm::Event::Blur) do
          @window.display.tput.lrestore_cursor :checkbox, true
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
        emit Crysterm::Event::Check, @value
      end

      def uncheck
        return unless checked?
        @checked = false
        @value = !@value
        emit Crysterm::Event::UnCheck, @value
      end

      def toggle
        checked? ? uncheck : check
      end
    end
  end
end
