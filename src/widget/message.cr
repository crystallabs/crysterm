require "./dialog"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![Message screenshot](../../tests/widget/message/message.5s.apng)
    # <!-- /widget-examples:capture -->
    class Message < Dialog
      # Previously set in the `class Widget` body, polluting every widget's
      # defaults. Belong here instead.
      @resizable = true
      @parse_tags = true

      @ev_keypress = Crysterm::Subscription.new

      def display(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        if scrollable?
          window.save_focus
          focus
          scroll_to 0
        end

        show
        set_content text
        request_render

        if !time || time.to_f <= 0
          # No timeout: dismiss on next keypress. (Previously slept 10s first,
          # making the message un-dismissable for 10s then linger until a key.)
          @ev_keypress.on(window, Crysterm::Event::KeyPress) do |_|
            @ev_keypress.off
            end_it do
              callback.try &.call
            end
          end

          return
        else
          spawn do
            sleep time

            # Route through `end_it` (as the keypress path does) so a
            # scrollable message restores focus instead of leaving it stranded.
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
            window.restore_focus
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

      # Severity of a message, mirroring Qt's `QMessageBox` icons. Each maps
      # to a colored leading glyph drawn before the text by `#display_with`.
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

      # Shows *text* prefixed with *severity*'s icon. General form behind
      # `#information`/`#warning`/`#critical`/`#question`.
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
