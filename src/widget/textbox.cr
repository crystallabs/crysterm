module Crysterm
  class Widget
    class TextBox < TextArea

      property secret : Bool = false
      property censor : Bool = false
      getter value : String = ""

      @scrollable = false

      def initialize(
        secret = nil,
        censor = nil,
        **textarea
      )

        super **textarea

        secret.try { |v| @secret = v }
        censor.try { |v| @censor = v }
      end

      def _listener(e : Crysterm::Event::KeyPress)
        if e.key == Tput::Key::Enter
          @_done.try &.call nil, @value
          return
        end
        super
      end

      def value=(value=nil)
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
            val = @value.gsub /\t/, @screen.tabc
            visible = (width - iwidth - 1)
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
