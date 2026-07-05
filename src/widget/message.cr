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

      # Bumped on every `#display`. A timed (or keypress) dismissal fiber
      # captures the value current when it was armed; when a newer `#display`
      # supersedes it the captured value no longer matches, so `#end_it`
      # no-ops — a stale timer can't dismiss a later message early (Finding 37).
      @generation = 0

      def display(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        gen = @generation += 1
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
            end_it gen do
              callback.try &.call
            end
          end

          return
        else
          spawn do
            sleep time

            # Route through `end_it` (as the keypress path does) so a
            # scrollable message restores focus instead of leaving it stranded.
            end_it gen do
              callback.try &.call
            end
          end
        end
      end

      # blessed's `Message#log` — a plain alias of `#display`. `alias_previous`
      # can't forward a block and `#display` requires one, so it's spelled out.
      # A block-less overload is provided for the common fire-and-forget call.
      def log(text, time : Time::Span? = Crysterm::Config.message_display_time)
        display(text, time) { }
      end

      def log(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        display(text, time, &callback)
      end

      # Remove the keypress-dismiss subscription (armed on the *window* by a
      # timeout-less `#display`) before teardown. Otherwise, if the message is
      # destroyed before any key is pressed, the next keypress runs `end_it`
      # against the destroyed widget — hiding it, re-rendering, and possibly
      # yanking focus in the rebuilt UI. `Subscription#off` is idempotent and
      # captures the window, so it works even after detach.
      def destroy
        @ev_keypress.off
        # Invalidate any armed *timed* dismissal fiber too: it captured the
        # generation live when it was spawned and will call `end_it` after its
        # sleep. Bumping the generation makes that `end_it` no-op, so a message
        # destroyed before its timeout can't hide/re-render/run its callback
        # against the torn-down widget — the timed analogue of the keypress
        # subscription teardown above.
        @generation += 1
        super
      end

      def end_it(gen : Int32? = nil, &callback : Proc(Nil))
        # A stale timer/keypress fiber from a superseded `#display` captured an
        # older generation; ignore it so it can't dismiss a newer message early.
        return if gen && gen != @generation
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
