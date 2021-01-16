require "./node"

module Crysterm
  module Widget
    # Text area element
    class TextArea < Input
      @_reading = false

      @scrollable = true
      @input_on_focus = false

      getter value : String = ""
      @_value = ""

      property _done : Proc(KeyPressEvent, Nil)?
      property __done : Proc(KeyPressEvent, Nil)?

      def initialize(
        @value = "",
        input_on_focus = false,
        scrollable = nil,
        keys = true,
        **input
      )
        scrollable.try { |v| @scrollable = v }

        super **input

        @screen._listen_keys self

        on(ResizeEvent) do
          _update_cursor
        end
        on(MoveEvent) do
          _update_cursor
        end

        self.input_on_focus= input_on_focus

        if !@input_on_focus && keys
          on(KeyPressEvent) do |e|
            next if @_reading
            if e.key.try &.==(Tput::Key::Enter)
              next read_input { |*stuff| p stuff }
            end
          end
        end

        # XXX if mouse...

      end

      def input_on_focus=(arg)
        # TODO if false, remove event listener
        # If true, set it
        on(FocusEvent) do |e|
          read_input { |*stuff| p stuff }
        end
      end

      #def _listener(e)
      #  case e.key
      #  when nil
      #    @value = @value + e.char
      #  when Tput::Key::Backspace
      #    @value = @value[...-1]
      #  end
      #  render
      #end

      #def _listen_keys
      #  on(KeyPressEvent) do |e|
      #    # TODO replace this with toggling of a flag on Focus/Unfocus event.
      #    next if @input_on_focus && (@screen.focused != self)
      #    next if @_reading

      #    if e.key.try &.==(Tput::Key::Enter)
      #      read_input
      #    end
      #  end
      #end

      def _listener(e)
        done = @_done
        value = @value

        if k = e.key
          #return if k == Tput::Key::Return
          ch = '\n' if k == Tput::Key::Enter

          # TODO handle directions
          if [Tput::Key::Left, Tput::Key::Up, Tput::Key::Right, Tput::Key::Down].includes? k
          end

          # XXX
          #if @keys && CtrlE
          #  # return(Invoke editor)
          #end

          # TODO can optimize by writing directly to screen buffer
          # here.
          if k == Tput::Key::Escape
            done
          elsif k == Tput::Key::Backspace
            if @value.size > 0
              # TODO if full unicode...
              if false
              else
                @value = @value[...-1]
              end
            end
          end

        elsif e.char # so, !e.key
          # XXX damn, to_s
          unless e.char.to_s.match /^[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f]$/
            @value += e.char
          end
        end

        if @value != value
          @screen.render
        end

      end

      def read_input(&callback : Proc(String, String, Nil))
        return if @_reading
        @_reading = true

        @_callback = callback

        if !focused?
          @screen.save_focus
          focus
        end

        @screen.grab_keys = true

        _update_cursor

        @screen.application.tput.show_cursor
        # D O:
        # @screen.application.tput.sgr "normal"

        # Define _done

        #@__listener = ->_listener
        on KeyPressEvent, ->_listener(KeyPressEvent)

        on(BlurEvent) {
          # TODO
          #@__done.try &.call
        }
      end

      def _done(err, data)
        return unless @_reading

        #return if self(block).done?

        @_reading = false

        @_callback = nil
        @_done = nil
        # XXX delete keypress listener
        @__listener = done
        #remove blur event
        @__done = nil

        @screen.application.tput.hide_cursor
        @screen.grab_keys = false

        unless focused?
          restore_focus
        end

        if @input_on_focus
          rewind_focus
        end

        # damn
        return if err == "stop"

        if err
          raise err # XXX just temporary
        elsif value
          emit SubmitEvent, value
        else
          emit CancelEvent, value
        end

        emit ActionEvent, value

        return unless callback

        callback.call err, value
      end

      def _update_cursor(get = false)
        return unless focused? #if @screen.focused != self

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

        # When calling clear_value on a full textarea with a border, the first
        # argument in the above Math.min call ends up being -2. Make sure we stay
        # positive.
        line = Math.max(0, line)

        cy = lpos.yi + itop + line
        cx = lpos.xi + ileft + str_width(last)

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

      def _type_scroll
        # XXX workaround
        h = @height - iheight
        if (@_clines.size - @child_base) > h
          # TODO
          # scroll @_clines.size
        end
      end

      def value=(value=nil)
        if value.nil?
          return self.value= @value
        end

        return if @_value == value

        @value = value
        @_value = value
        set_content value
        _type_scroll
        _update_cursor
      end

      def render
        self.value=()
        super # OR _render
      end

      def submit
        #@__listener.try &.call KeyPressEvent.new '\n', Tput::Key::Enter
        _listener KeyPressEvent.new '\n', Tput::Key::Enter
      end
      def cancel
        #@__listener.try &.call KeyPressEvent.new '\e', Tput::Key::Escape
        _listener KeyPressEvent.new '\e', Tput::Key::Escape
      end

      def clear_value
        self.value= ""
      end
    end
  end
end
