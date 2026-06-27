require "./dialog"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![Message screenshot](../../examples/widget/message/message-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Message < Dialog
      # These were previously set in the `class Widget` body (outside `Message`),
      # which polluted every widget's defaults and left `Message` itself
      # unscoped. They belong to `Message`.
      @resizable = true
      @parse_tags = true

      @ev_keypress : Crysterm::Event::KeyPress::Wrapper?

      def display(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        if scrollable?
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
          @ev_keypress = screen.on(Crysterm::Event::KeyPress) do |_|
            @ev_keypress.try do |w|
              screen.off ::Crysterm::Event::KeyPress, w
            end
            end_it do
              callback.try &.call
            end
          end

          return
        else
          spawn do
            sleep time

            # Route the timed dismissal through `end_it` (as the keypress path
            # does) so a scrollable message that grabbed focus on show restores
            # it. Hiding directly here left focus stranded on the dismissed
            # message. For a non-scrollable message `end_it` skips the restore,
            # so its behaviour (hide + request_render + callback) is unchanged.
            end_it do
              callback.try &.call
            end
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
