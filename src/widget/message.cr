module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![Message screenshot](../../examples/widget/message/message-capture.png)
    # <!-- /widget-examples:capture -->
    class Message < Box
      # These were previously set in the `class Widget` body (outside `Message`),
      # which polluted every widget's defaults and left `Message` itself
      # unscoped. They belong to `Message`.
      @resizable = true
      @parse_tags = true

      @ev_keypress : Crysterm::Event::KeyPress::Wrapper?

      def display(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
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
        request_render

        if !time || time.to_f <= 0
          # No timeout: dismiss on the next keypress. Install the handler
          # immediately. (It used to `sleep 10.seconds` first, which made the
          # message un-dismissable for 10s and then linger until a key.)
          begin
            @ev_keypress = screen.on(Crysterm::Event::KeyPress) do |_|
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
            request_render
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
        request_render
        callback.try &.call
      end

      def error(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        # `display` takes its callback as a block, not a positional arg.
        display("{red-fg}Error: #{text}{/red-fg}", time, &callback)
      end

      # Severity of a message, mirroring the icons of Qt's `QMessageBox`
      # (`Information`, `Warning`, `Critical`, `Question`). Each maps to a colored
      # leading glyph drawn before the text by `#display_with`.
      enum Severity
        None
        Information
        Warning
        Critical
        Question

        # Tagged (color + glyph) prefix shown ahead of the message text.
        def prefix : String
          case self
          in None        then ""
          in Information then "{blue-fg}ℹ{/blue-fg}  "
          in Warning     then "{yellow-fg}⚠{/yellow-fg}  "
          in Critical    then "{red-fg}✖{/red-fg}  "
          in Question    then "{cyan-fg}?{/cyan-fg}  "
          end
        end
      end

      # Shows *text* prefixed with *severity*'s icon (see `Severity`). This is the
      # general form behind the `#information`/`#warning`/`#critical`/`#question`
      # convenience helpers.
      def display_with(severity : Severity, text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        display("#{severity.prefix}#{text}", time, &callback)
      end

      def information(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        display_with(Severity::Information, text, time, &callback)
      end

      def warning(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        display_with(Severity::Warning, text, time, &callback)
      end

      def critical(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        display_with(Severity::Critical, text, time, &callback)
      end

      def question(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        display_with(Severity::Question, text, time, &callback)
      end
    end
  end
end
