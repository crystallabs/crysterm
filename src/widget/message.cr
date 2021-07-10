module Crysterm
  class Widget
    # TODO Check if this is honored
    @resizable = true
    @parse_tags = true

    class Message < Box
      @ev_keypress : Crysterm::Event::KeyPress::Wrapper?

      def display(text, time : Time::Span? = 10.seconds, &callback : Proc(Nil))
        # D O:
        # Keep above:
        # parent = @parent
        # detach
        # parent.append self

        if @scrollable
          screen.save_focus
          focus
          scroll_to 0
        end

        show
        set_content text
        screen.render

        if !time || time.to_f <= 0
          spawn do
            sleep 10.seconds

            @ev_keypress = screen.on(Crysterm::Event::KeyPress) do |e|
              #  ##return if e.key.try(&.name) == ::Tput::Key::Mouse # XXX
              #  #if scrollable?
              #  #  if (e.key == ::Tput::Key::Up) || # || (@vi && e.char == 'k') # XXX
              #  #    (e.key == ::Tput::Key::Down) # || (@vi && e.char == 'j')) # XXX
              #  #    #(@vi && e.key == 'u' && e.key.control?) # XXX
              #  #    #(@vi && e.key == 'd' && e.key.control?)
              #  #    #(@vi && e.key == 'b' && e.key.control?)
              #  #    #(@vi && e.key == 'f' && e.key.control?)
              #  #    #(@vi && e.key == 'g' && !e.key.shift?)
              #  #    #(@vi && e.key == 'g' && e.key.shift?)
              #  #    return
              #  #  end
              #  #end
              #  if @ignore_keys.includes? e.key # XXX
              #    return
              #  end
              @ev_keypress.try do |w|
                screen.off ::Crysterm::Event::KeyPress, w
              end
              end_it do
                callback.try &.call
              end
            end
            # XXX May be affected by new @mouse option.
            # return unless @mouse
            # on_screen_event(::Tput::Key::Mouse) do |e|
            #  #return if data.action == ::Tput::Mouse::Move
            #  remove_screen_event(::Tput::Key::Mouse, fn_wrapper)
            #  end_it callback
            # end
          end

          return
        else
          spawn do
            sleep time

            hide
            screen.render
            callback.try &.call
          end
        end
      end

      alias_previous log

      def end_it(&callback : Proc(Nil))
        # return if end_it.done # XXX
        # end_it.done = true
        if scrollable?
          begin
            screen.restore_focus
          rescue
          end
        end
        hide
        screen.render
        callback.try &.call
      end

      def error(text, time, callback)
        display "{red-fg}Error: #{text}{/red-fg}", time, callback
      end
    end
  end
end
