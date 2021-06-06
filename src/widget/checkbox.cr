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

      @ev_keypress : Crysterm::Event::KeyPress::Wrapper?
      @ev_click : Crysterm::Event::Click::Wrapper?
      @ev_focus : Crysterm::Event::Focus::Wrapper?
      @ev_blur : Crysterm::Event::Blur::Wrapper?

      def initialize(checked : Bool = false, value : Bool? = nil, **input)
        super **input

        @checked = checked

        @value = value.nil? ? checked : value

        input["content"]?.try do |c|
          @text = c
        end

        on(::Crysterm::Event::Attach) do
          @ev_keypress = on(Crysterm::Event::KeyPress) do |e|
            # if e.key == Tput::Key::Enter || e.key == Tput::Key::Space
            if e.key == Tput::Key::Enter || e.char == ' '
              e.accept!
              toggle
              screen.render
            end
          end

          @ev_click = on(Crysterm::Event::Click) do
            toggle
            screen.render
          end

          @ev_focus = on(Crysterm::Event::Focus) do
            next unless lpos = @lpos
            screen.display.tput.lsave_cursor :checkbox
            screen.display.tput.cursor_pos lpos.yi, lpos.xi + 1
            screen.display.tput.show_cursor
          end

          @ev_blur = on(Crysterm::Event::Blur) do
            screen.display.tput.lrestore_cursor :checkbox, true
          end
        end

        on(::Crysterm::Event::Detach) do
          @ev_keypress.try do |ev|
            screen.off ::Crysterm::Event::KeyPress, ev
          end
          @ev_click.try do |ev|
            screen.off ::Crysterm::Event::Click, ev
          end
          @ev_focus.try do |ev|
            screen.off ::Crysterm::Event::Focus, ev
          end
          @ev_blur.try do |ev|
            screen.off ::Crysterm::Event::Blur, ev
          end
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
