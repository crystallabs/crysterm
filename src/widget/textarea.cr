require "./node"

module Crysterm
  module Widget
    # Text area element
    class TextArea < Box
      @_reading = false

      @scrollable = true
      @input_on_focus = false

      getter value = ""
      @_value = ""

      def initialize(
        @input_on_focus = false,
        @scrollable = true,
        **input
      )
        super **input

        on(ResizeEvent) do
          _update_cursor
        end
        on(MoveEvent) do
          _update_cursor
        end

        # _listen_keys

        on KeyPressEvent, ->_listener(KeyPressEvent)
      end

      def _listener(e)
        case e.key
        when nil
          @value = @value + e.char
        when Tput::Key::Backspace
          @value = @value[...-1]
        end
        render
      end

      def _listen_keys
        on(KeyPressEvent) do |e|
          # TODO replace this with toggling of a flag on Focus/Unfocus event.
          next if @input_on_focus && (@screen.focused != self)
          next if @_reading

          if e.key.try &.==(Tput::Key::Enter)
            read_input
          end
        end
      end

      def read_input(&callback : Proc(String, String, Nil))
        return if @_reading
        @_reading = true

        focused = @screen.focused == self

        if !focused
          @screen.save_focus
          focus
        end

        # TODO
        # grab_keys -> yes

        _update_cursor
        @screen.application.tput.show_cursor
        # D O:
        # @screen.application.tput.sgr "normal"
      end

      def _update_cursor(get = false)
        return if @screen.focused != self

        lpos = get ? @lpos : _get_coords
        return unless lpos

        last = @_clines[-1]
        app = @screen.application

        # Stop a situation where the textarea begins scrolling
        # and the last cline appears to always be empty from the
        # _type_scroll `+ '\n'` thing.
        # Maybe not necessary anymore?
        if (last == "" && @value[-1]? != '\n')
          last = @_clines[-2]? || ""
        end

        line = Math.min(
          @_clines.size - 1 - (@child_base || 0),
          (lpos.yl - lpos.yi) - iheight - 1
        )

        # When calling clear_value() on a full textarea with a border, the first
        # argument in the above Math.min call ends up being -2. Make sure we stay
        # positive.
        line = Math.max(0, line)

        cy = lpos.yi + itop + line
        # TODO -- don't check size but string width!!
        cx = lpos.xi + ileft + (last).size

        # XXX Not sure, but this may still sometimes
        # cause problems when leaving editor.
        if (cy == @screen.application.tput.cursor.y && cx == @screen.application.tput.cursor.x)
          return
        end

        if (cy == @screen.application.tput.cursor.y)
          if (cx > @screen.application.tput.cursor.x)
            app.tput.cuf(cx - @screen.application.tput.cursor.x)
          elsif (cx < @screen.application.tput.cursor.x)
            app.tput.cub(@screen.application.tput.cursor.x - cx)
          end
        elsif (cx === @screen.application.tput.cursor.x)
          if (cy > @screen.application.tput.cursor.y)
            app.tput.cud(cy - @screen.application.tput.cursor.y)
          elsif (cy < @screen.application.tput.cursor.y)
            app.tput.cuu(@screen.application.tput.cursor.y - cy)
          end
        else
          app.tput.cup(cy, cx)
        end
      end

      def clear_value
        @value = ""
      end

      def set_value(value)
        # TODO
        return if @_value == @value

        @value = value
        @_value = value
        STDERR.puts @value
        set_content "ABC"
        _type_scroll
        _update_cursor
        render
      end

      def set_value
        set_value @value
      end

      def _type_scroll
        # XXX workaround
        if (@_clines.size - @child_base) > (@height - iheight)
          # TODO
          # scroll @_clines.size
        end
      end

      def render
        set_value
        super
      end

      def cancel
      end
    end
  end
end
