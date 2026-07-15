require "./dialog"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![Message screenshot](../../tests/widget/message/message.5s.apng)
    # <!-- /widget-examples:capture -->
    class Message < Dialog
      # Generation-guarded timed dismissal: `#display` bumps the counter; a timed
      # (or keypress) dismissal fiber captures the value current when it was
      # armed, and `#end_it` no-ops once a newer `#display` supersedes it — a
      # stale timer can't dismiss a later message early.
      include ::Crysterm::Mixin::TimedDismissal

      # Kept here rather than in the `class Widget` body, where they would
      # pollute every widget's defaults.
      @shrink_to_fit = true
      @parse_tags = true

      @ev_keypress = Crysterm::Subscription.new

      # The in-flight `#display`'s callback, so a programmatic `#accept` runs the
      # same dismissal the key/timeout paths do instead of closing behind
      # `#display`'s back (leaving its callback unfired).
      @dismiss_callback : Proc(Nil)? = nil

      # Shows *text* until *time* elapses (or, without a timeout, until the next
      # keypress), then dismisses it and runs *callback* — the block-based sugar
      # over the `Dialog` result protocol. A message carries only an
      # acknowledgement, so every dismissal closes with `Code::Accepted`
      # (`Event::Accepted`, then `Event::Finished`).
      def display(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        gen = bump_dismiss_gen
        @dismiss_callback = callback
        @result = Code::Rejected.to_i
        if scrollable?
          window.save_focus
          focus
          scroll_to 0
        end

        show
        set_content text
        request_render

        if !time || time.to_f <= 0
          # No timeout: dismiss on next keypress.
          @ev_keypress.on(window, Crysterm::Event::KeyPress) do |_|
            @ev_keypress.off
            end_it gen do
              callback.try &.call
            end
          end

          return
        else
          # Route through `end_it` (as the keypress path does) so a
          # scrollable message restores focus instead of leaving it stranded.
          after time do
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
        bump_dismiss_gen
        # Drop the pending callback with it: nothing may dismiss the message any
        # more, so holding it would only pin the closure to a dead widget.
        @dismiss_callback = nil
        super
      end

      # Dismisses the message and runs *callback*. Internal: the generation
      # counter *gen* is `#display`'s stale-fiber guard, not something a caller
      # can meaningfully supply — dismiss from outside with `#accept`.
      protected def end_it(gen : Int32? = nil, &callback : Proc(Nil))
        # A stale timer/keypress fiber from a superseded `#display` captured an
        # older generation; ignore it so it can't dismiss a newer message early.
        return if gen && !dismiss_current?(gen)
        if scrollable?
          begin
            window.restore_focus
          rescue
          end
        end
        @dismiss_callback = nil
        # A message has only an acknowledgement, so any dismissal — key, timeout
        # or `#accept` — is the affirmative outcome. `Dialog#done` hides it and
        # emits `Event::Accepted` + `Event::Finished`.
        done Code::Accepted
        callback.try &.call
      end

      # Dismisses the message programmatically, exactly as a keypress/timeout
      # would: restores focus, runs the pending `#display` callback, and closes
      # with `Code::Accepted`. Also invalidates any armed dismissal fiber, so it
      # can't fire the callback a second time.
      def accept : Nil
        @ev_keypress.off
        cb = @dismiss_callback
        bump_dismiss_gen
        end_it { cb.try &.call }
      end

      # :ditto: a message has no negative outcome to report — dismissing it *is*
      # acknowledging it — so Escape/Cancel resolves the same way as `#accept`.
      def reject : Nil
        accept
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

        # Tagged (color + glyph) prefix shown ahead of the message text, with
        # the icon from the `Glyphs` registry at *tier*.
        def prefix(tier : Glyphs::Tier = Glyphs::Tier::Unicode) : String
          case self
          in None        then ""
          in Information then "{blue-fg}#{Glyphs[Glyphs::Role::IconInfo, tier]}{/blue-fg}  "
          in Warning     then "{yellow-fg}#{Glyphs[Glyphs::Role::IconWarning, tier]}{/yellow-fg}  "
          in Critical    then "{red-fg}#{Glyphs[Glyphs::Role::IconCritical, tier]}{/red-fg}  "
          in Question    then "{cyan-fg}#{Glyphs[Glyphs::Role::IconQuestion, tier]}{/cyan-fg}  "
          end
        end
      end

      # Shows *text* prefixed with *severity*'s icon. General form behind
      # `#information`/`#warning`/`#critical`/`#question`.
      def display_with(severity : Severity, text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        display("#{severity.prefix(glyph_tier)}#{text}", time, &callback)
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
