module Crysterm
  class Widget
    # Text area element
    class TextArea < Input
      @_reading = false

      @scrollable = true
      @input_on_focus = false

      property __update_cursor : Proc(Nil)?

      property value : String = ""
      @_value = ""

      property _done : Proc(String?, String?, Nil)?
      property __done : Proc(String?, String?, Nil)?
      property __listener : Proc(Crysterm::Event::KeyPress, Nil)?

      @ev_read_input_on_focus : Crysterm::Event::Focus::Wrapper?
      @ev_enter : Crysterm::Event::KeyPress::Wrapper?
      @ev_reading : Crysterm::Event::KeyPress::Wrapper?

      def initialize(
        input_on_focus = false,
        keys = true,
        **input
      )
        # Will be taken care of by default above, and parent
        # scrollable.try { |v| @scrollable = v }

        @value = input["content"]? || ""

        super **input

        @screen._listen_keys self

        @__update_cursor = ->_update_cursor

        on(Crysterm::Event::Resize) do
          @__update_cursor.try &.call
        end
        on(Crysterm::Event::Move) do
          @__update_cursor.try &.call
        end

        self.input_on_focus = input_on_focus

        if !@input_on_focus && keys
          @ev_enter = on(Crysterm::Event::KeyPress) do |e|
            next if @_reading
            if e.key.try &.==(Tput::Key::Enter)
              next read_input
            end
          end
        end

        # XXX if mouse...
      end

      def _update_cursor(get = false)
        return unless focused? # if @screen.focused != self

        lpos = get ? @lpos : _get_coords
        return unless lpos

        last = @_clines[-1]
        app = @screen.display

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
        # E O:
        # if (cy == app.tput.cursor.y) && (cx == app.tput.cursor.x)
        #  return
        # end
        # That check is redundant because the below logic also does
        # the same (no-op if cursor is already at coords.)

        if (cy == app.tput.cursor.y)
          if (cx > app.tput.cursor.x)
            app.tput.cuf(cx - app.tput.cursor.x)
          elsif (cx < app.tput.cursor.x)
            app.tput.cub(app.tput.cursor.x - cx)
          end
        elsif (cx == app.tput.cursor.x)
          if (cy > app.tput.cursor.y)
            app.tput.cud(cy - app.tput.cursor.y)
          elsif (cy < app.tput.cursor.y)
            app.tput.cuu(app.tput.cursor.y - cy)
          end
        else
          app.tput.cup(cy, cx)
        end
      end

      def input_on_focus=(yes)
        @input_on_focus = yes

        # Always remove any current handler
        @ev_read_input_on_focus.try { |w| off Crysterm::Event::Focus, w }

        # Then add the new one if asked
        if yes
          @ev_read_input_on_focus = on(Crysterm::Event::Focus) do # |e|
            read_input
          end
        end

        # (Alternatively we could do nothing if a handler
        # is already installed and yes==true).
      end

      def _listener(e)
        done = @_done
        value = @value
        also_check_char = false

        if k = e.key
          # return if k == Tput::Key::Return
          if k == Tput::Key::Enter
            e.char = '\n'
            also_check_char = true
          end

          # TODO handle directions
          if [Tput::Key::Left, Tput::Key::Up, Tput::Key::Right, Tput::Key::Down].includes? k
          end

          # XXX
          # if @keys && CtrlE
          #  # return(Invoke editor)
          # end

          # TODO can optimize by writing directly to screen buffer
          # here.
          if k == Tput::Key::Escape
            done.try &.call nil, nil
          elsif k == Tput::Key::Backspace
            if @value.size > 0
              # TODO if full unicode...
              if false
              else
                @value = @value[...-1]
              end
            end
          end
        end

        if e.char && (!e.key || also_check_char)
          # XXX damn, to_s
          unless e.char.to_s.match /^[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f]$/
            @value += e.char
          end
        end

        if @value != value
          @screen.render
        end
      end

      def _type_scroll
        # O: XXX workaround
        h = height - iheight
        if (@_clines.size - @child_base) > h
          scroll @_clines.size
        end
      end

      def value=(value = nil)
        if value.nil?
          value = @value
        end

        return if @_value == value

        @value = value
        @_value = value
        set_content value
        _type_scroll
        _update_cursor
      end

      def render
        self.value = nil
        super # OR _render
      end

      def submit
        # @__listener.try &.call Crysterm::Event::KeyPress.new '\n', Tput::Key::Enter
        return unless @__listener
        @__listener.try &.call Crysterm::Event::KeyPress.new '\n', Tput::Key::Enter
      end

      def cancel
        # @__listener.try &.call Crysterm::Event::KeyPress.new '\e', Tput::Key::Escape
        return unless @__listener
        @__listener.try &.call Crysterm::Event::KeyPress.new '\e', Tput::Key::Escape
      end

      def clear_value
        self.value = ""
      end

      def _read_input
        if !focused?
          @screen.save_focus
          focus
        end

        @screen.grab_keys = true

        _update_cursor
        @screen.display.tput.show_cursor

        # D O:
        # @screen.display.tput.sgr "normal"

        # Define _done_default

        @__listener = ->_listener(Crysterm::Event::KeyPress)

        # @ev_reading.try { |w| off Crysterm::Event::KeyPress, w }

        @ev_reading = on(Crysterm::Event::KeyPress) { |e|
          @__listener.try &.call e
        }

        @__done = ->_done_default(String?, String?)

        on(Crysterm::Event::Blur) {
          @__done.try &.call nil, nil
        }
      end

      def read_input(&callback : Proc(String, String, Nil))
        return if @_reading
        @_reading = true
        @_callback = callback
        _read_input
      end

      def read_input
        return if @_reading
        @_reading = true
        @_callback = nil
        _read_input
      end

      def __done_default(err = nil, data = nil)
        return unless @_reading

        # return if self(block).done?

        @ev_reading.try { |w| off Crysterm::Event::KeyPress, w }
        @_reading = false

        @_callback = nil
        @_done = nil
        # XXX off Crysterm::Event::KeyPress, @__listener.wrapper
        @__listener = nil
        # XXX off Crysterm::Event::Blur, @__done.wrapper
        @__done = nil

        @screen.display.tput.hide_cursor
        @screen.grab_keys = false

        unless focused?
          @screen.restore_focus
        end

        if @input_on_focus
          # TODO causes Error running at_exit handler: Index out of bounds
          # @screen.rewind_focus
        end

        # damn
        return if err == "stop"

        if err
          raise err # XXX just temporary
        elsif value
          emit Crysterm::Event::Submit, value
        else
          emit Crysterm::Event::Cancel, value
        end

        emit Crysterm::Event::Action, value

        nil
      end

      def _done_default(err = nil, data = nil)
        __done_default err, data
      end

      def _done_default(err = nil, data = nil, &callback : Proc(String, String, Nil))
        __done_default err, data
        callback.call err, value
      end
    end
  end
end
