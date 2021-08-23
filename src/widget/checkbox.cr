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

      # TODO checkboxes don't have keys enabled by default, so to be
      # navigable via keys, they need `screen.enable_keys(checkbox_obj)`.

      property? checked : Bool = false
      property value : Bool = false
      property text : String = ""

      # def initialize(checked : Bool = false, value : Bool? = nil, **input)
      def initialize(@checked : Bool = false, **input)
        super **input

        # @value = value.nil? ? checked : value
        @value = @checked

        input["content"]?.try do |c|
          @text = c
        end

        on Crysterm::Event::KeyPress, ->on_keypress(Crysterm::Event::KeyPress)
        on Crysterm::Event::Focus, ->on_focus(Crysterm::Event::Focus)
        on Crysterm::Event::Blur, ->on_blur(Crysterm::Event::Blur)
        # XXX potentially wrap in `if mouse`?
        on Crysterm::Event::Click, ->on_click(Crysterm::Event::Click)
      end

      def render
        clear_last_rendered_position true
        set_content ("[" + (checked? ? 'x' : ' ') + "] " + @text), true
        super false
      end

      def check
        return if checked?
        @checked = @value = true
        # @value = !@value
        emit Crysterm::Event::Check, @value
      end

      def uncheck
        return unless checked?
        @checked = @value = false
        # @value = !@value
        emit Crysterm::Event::UnCheck, @value
      end

      def toggle
        checked? ? uncheck : check
      end

      def on_keypress(e)
        # if e.key == Tput::Key::Enter || e.key == Tput::Key::Space
        if e.key == Tput::Key::Enter || e.char == ' '
          e.accept!
          toggle
          screen.try &.render
        end
      end

      def on_click(e)
        toggle
        screen.try &.render
      end

      def on_focus(e)
        return unless lpos = @lpos
        screen.try do |s|
          s.display.tput.lsave_cursor self.hash
          s.display.tput.cursor_pos lpos.yi, lpos.xi + 1
          s.show_cursor
        end
      end

      def on_blur(e)
        screen.try do |s|
          s.display.tput.lrestore_cursor self.hash, true
        end
      end
    end
  end
end
