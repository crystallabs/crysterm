module Crysterm
  class Widget
    class TextBox < TextArea
      property secret : Bool = false
      property censor : Bool = false
      getter value : String = ""

      def initialize(
        secret = nil,
        censor = nil,
        parse_tags = false,
        input_on_focus = true,
        scrollable = false,
        **textarea
      )
        super **textarea, parse_tags: parse_tags, input_on_focus: input_on_focus, scrollable: scrollable

        secret.try { |v| @secret = v }
        censor.try { |v| @censor = v }
      end

      def _listener(e : Crysterm::Event::KeyPress)
        if e.key == Tput::Key::Enter
          e.accept
          @_done.try do |done2|
            done2.call nil, @value
          end
          return
        end
        super
      end

      def value=(value = nil)
        value ||= @value

        if @_value != value
          value = value.gsub /\n/, ""
          @value = value
          @_value = value

          if @secret
            set_content ""
          elsif @censor
            set_content "*" * value.size
          else
            val = @value.gsub /\t/, @tabc
            visible = (awidth - iwidth - 1)
            if visible > val.size
              visible = val.size
            end
            set_content val[-visible..]
          end

          _update_cursor
        end
      end

      def submit
        @__listener.try &.call Crysterm::Event::KeyPress.new '\r', Tput::Key::Enter
      end
    end
  end
end
