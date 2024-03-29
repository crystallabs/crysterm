require "./input"

module Crysterm
  class Widget
    # Checkbox element
    class CheckBox < Input
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

        handle Crysterm::Event::KeyPress
        handle Crysterm::Event::Focus
        handle Crysterm::Event::Blur
        # XXX potentially wrap in `if mouse`?
        handle Crysterm::Event::Click
      end

      def render
        clear_last_rendered_position true
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

      def on_keypress(e)
        # if e.key == Tput::Key::Enter || e.key == Tput::Key::Space
        if e.key == Tput::Key::Enter || e.char == ' '
          e.accept
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
          s.tput.lsave_cursor self.hash
          s.tput.cursor_pos lpos.yi + itop, lpos.xi + 1 + ileft
          # s.show_cursor # XXX
        end
      end

      def on_blur(e)
        screen.try do |s|
          s.tput.lrestore_cursor self.hash, true
        end
      end
    end

    alias Checkbox = CheckBox
  end
end
