require "./dialog"

module Crysterm
  class Widget
    # Modal message box, modeled after Qt's `QMessageBox`.
    #
    # One class covers both jobs a message box does:
    #
    # * **Notification** — `#open(text, time)` shows *text* until the timeout
    #   elapses (or, without one, until the next keypress). Severity presets
    #   (`#information`/`#warning`/`#critical`/`#question`, and their one-call
    #   class counterparts) prefix a colored icon.
    # * **Question** — `#open(text) { |yes| … }` shows the same body with the
    #   OK/Cancel pair and delivers a yes/no answer; `#open(text, choices) { |i| … }`
    #   presents an arbitrary row of choices instead.
    #
    # Every form funnels through the `Dialog` result protocol (`#result`,
    # `Event::Accepted`/`Rejected`/`Finished`) and takes the modal grab, so the
    # verb is always `#open` — the same verb `Dialog#open` already carries.
    #
    # ```
    # Widget::MessageBox.information window, "Saved."
    # Widget::MessageBox.ask(window, "Delete this file?") { |yes| rm if yes }
    # ```
    #
    # Excluded from the DOM-loader registry: self-populating composite
    # (see `Crysterm::DOM::Skip`).
    @[::Crysterm::DOM::Skip]
    # <!-- widget-examples:capture v1 -->
    # ![MessageBox screenshot](../../tests/widget/message_box/message_box.5s.apng)
    # <!-- /widget-examples:capture -->
    class MessageBox < Dialog
      # Generation-guarded timed dismissal: a notification `#open` bumps the
      # counter; a timed (or keypress) dismissal fiber captures the value current
      # when it was armed, and `#end_it` no-ops once a newer `#open` supersedes
      # it — a stale timer can't dismiss a later message early.
      include ::Crysterm::Mixin::TimedDismissal

      # The OK/Cancel pair used by the question forms.
      include ::Crysterm::Mixin::OkCancelDialog

      @shrink_to_fit = true
      @parse_tags = true

      @ev_keypress = Crysterm::Subscription.new

      # The in-flight notification `#open`'s callback, so a programmatic
      # `#accept` runs the same dismissal the key/timeout paths do instead of
      # closing behind its back (leaving its callback unfired).
      @dismiss_callback : Proc(Nil)? = nil

      # The fixed OK/Cancel pair, bottom-right anchored so it adapts to the
      # dialog size (see `OkCancelDialog.ok_button`). Hidden until a question
      # form shows them — a plain notification carries no buttons. For an
      # arbitrary number of choices laid out in a row, use the `choices:`
      # form of `#open` (which builds a `DialogButtonBox`).
      @ok : Button = ::Crysterm::Mixin::OkCancelDialog.ok_button
      @cancel : Button = ::Crysterm::Mixin::OkCancelDialog.cancel_button

      # Pending-question state, reachable from `#destroy` so a dialog torn down
      # while an answer is outstanding leaves nothing on the window.
      #
      # `@ask_keys` is the window-level `KeyPress` accelerator: a `Subscription`
      # captures the window it was installed on, so `#off` works even after the
      # dialog has detached (where `window?` is already nil) — unlike a raw
      # `window.on` handle, whose removal would need a live `window` and raise
      # post-destroy.
      @ask_keys = ::Crysterm::Subscription.new

      # The OK/Cancel `Clicked` handles, so `#destroy` can run the same
      # `teardown_ok_cancel` the normal `finish` path does.
      @ev_ok : ::EventHandler::Subscription? = nil
      @ev_cancel : ::EventHandler::Subscription? = nil

      # The outstanding answer callbacks. Nil whenever no question is pending;
      # `finish` nils its own before invoking it (idempotence latch), and
      # `#destroy` nils them so a stray handler can never fire on the dead
      # dialog.
      @ask_block : ::Proc(Bool, ::Nil)? = nil
      @ask_choices_block : ::Proc(Int32?, ::Nil)? = nil

      def initialize(ok_text = nil, cancel_text = nil, **box)
        super **box

        # Dialogs start hidden; `#open` reveals them. Otherwise the box renders
        # on the first frame, and dialogs sharing a window stack up.
        hide

        # Custom button labels (Qt lets you relabel the standard buttons).
        ok_text.try { |t| @ok.set_content t }
        cancel_text.try { |t| @cancel.set_content t }

        append @ok
        append @cancel

        # A notification carries no buttons; the question forms show them.
        @ok.hide
        @cancel.hide
      end

      # ---- Notification form ---------------------------------------------------

      # Shows *text* until *time* elapses (or, without a timeout, until the next
      # keypress), then dismisses it and runs *callback* — the block-based sugar
      # over the `Dialog` result protocol. A notification carries only an
      # acknowledgement, so every dismissal closes with `Code::Accepted`
      # (`Event::Accepted`, then `Event::Finished`).
      def open(text, time : Time::Span?, &callback : Proc(Nil))
        gen = bump_dismiss_gen
        @dismiss_callback = callback
        @result = Code::Rejected.to_i
        if scrollable?
          window.save_focus
          focus
          scroll_to 0
        end

        # `show_modal` (not a bare `show`) so the box paints on top of its
        # siblings and takes the pointer grab — no widget beneath it stays
        # clickable while it's up, matching every other `Dialog` presenter. The
        # grab is pointer-only (`Window#add_popup_grab`), so the below
        # dismiss-on-any-keypress path still receives keys; every close path
        # (`#end_it`→`#done`, and `#destroy`) releases the grab.
        show_modal
        set_content text
        update!

        if !time || time.to_f <= 0
          # No timeout: dismiss on next keypress.
          @ev_keypress.on(window, Crysterm::Event::KeyPress) do |e|
            @ev_keypress.off
            # Mark handled — otherwise the dismissing key (e.g. 'q') falls
            # through to `Application#route_input`'s default quit keys.
            e.accept
            end_it gen do
              callback.try &.call
            end
          end

          return
        else
          # Route through `end_it` so a scrollable message restores focus
          # instead of leaving it stranded.
          after time do
            end_it gen do
              callback.try &.call
            end
          end
        end
      end

      # Block-less overload for the common fire-and-forget call.
      def open(text, time : Time::Span? = Crysterm::Config.message_display_time)
        open(text, time) { }
      end

      # ---- Question form -------------------------------------------------------

      # Asks *text* and delivers the yes/no answer to *block* — the block-based
      # sugar over the `Dialog` result protocol: an affirmative answer closes
      # with `Code::Accepted` (`Event::Accepted`), a negative one with
      # `Code::Rejected` (`Event::Rejected`), and `Event::Finished` follows
      # either way.
      def open(text = nil, &block : Bool ->)
        begin_question
        begin_modal_content text

        @ok.show
        @cancel.show

        # Publish the pending callback on the instance so `#destroy` can reach
        # (and cancel) it. It doubles as the idempotence latch below.
        @ask_block = block

        # Declare the OK/Cancel handles up front so `finish` can close over them;
        # assigned below, before any of these events can fire.
        ev_ok = nil
        ev_cancel = nil

        # `finish` must be defined *before* the handlers that call it are
        # registered: a key/press arriving before assignment would invoke an
        # uninitialized Proc.
        finish = ->(data : Bool) do
          # `@ask_block` is the done-latch: `event_handler` emits to a
          # copy-on-write snapshot, so removing the in-flight key handler can't
          # stop a second delivery this frame; nilling the block first (Enter on
          # a focused button fires both the button's Press handler and the
          # window accelerator) keeps the user callback single-shot.
          if blk = @ask_block
            @ask_block = nil
            teardown_ok_cancel ev_ok, ev_cancel
            # A `Subscription` removes via the window it captured, so this is
            # safe even once the dialog has detached.
            @ask_keys.off
            # Record the outcome and signal it before the block runs, so a
            # `Finished` handler and the block see the same `#result`.
            done(data ? Code::Accepted : Code::Rejected)
            blk.call data
            update!
          end
        end

        @ask_keys.on(window, Crysterm::Event::KeyPress) do |e|
          # A focused button already handled (and accepted) this Enter — don't
          # also run the window-level accelerator, or `finish` double-fires.
          next if e.accepted?
          c = e.char
          k = e.key

          if k != Tput::Key::Enter && k != Tput::Key::Escape && c != 'q' && c != 'y' && c != 'n'
            next
          end

          # Mark this KeyPress handled before `finish` — otherwise an
          # un-accepted 'q' reaches `Application#route_input`'s default quit
          # keys and kills the app after the dialog already answered it.
          e.accept
          finish.call(k == Tput::Key::Enter || e.char == 'y')
        end

        ev_ok = @ev_ok = @ok.on(Crysterm::Event::Clicked) do
          finish.call true
        end

        ev_cancel = @ev_cancel = @cancel.on(Crysterm::Event::Clicked) do
          finish.call false
        end

        window.save_focus
        focus

        update!
      end

      # Asks the user to pick one of an arbitrary list of *choices*. The block
      # receives the chosen 0-based index, or `nil` if dismissed with Escape.
      # Buttons are laid out in a row; Left/Right move focus, Enter/Space or a
      # click activates the focused one.
      #
      # The index rides the block, not `Dialog#result`: picking any choice closes
      # with `Code::Accepted`, Escape with `Code::Rejected`. Feeding the index
      # into `#result` would collide with Qt's codes (choice `1` would read as
      # `Accepted`).
      def open(text : String?, choices : Array(String), default = 0, &block : Int32? ->)
        begin_question
        begin_modal_content text

        # The fixed OK/Cancel pair is not used in this mode.
        @ok.hide
        @cancel.hide

        # The choice buttons carry `Role::Apply`, so the box emits no
        # accept/reject signal — each choice's meaning is its index, wired on its
        # own `Clicked` below.
        bb = DialogButtonBox.new parent: self, top: 4, left: 1
        choices.each { |label| bb.add_button label, DialogButtonBox::Role::Apply }
        buttons = bb.buttons

        cur = default.clamp(0, Math.max(0, buttons.size - 1))

        # Publish the pending callback on the instance so `#destroy` can reach
        # (and cancel) it. It also latches `finish` against a double-fire.
        @ask_choices_block = block

        finish = ->(idx : Int32) do
          if blk = @ask_choices_block
            @ask_choices_block = nil
            # A `Subscription` removes via the window it captured, so this is
            # safe even once the dialog has detached.
            @ask_keys.off
            # Move focus onto a surviving widget *before* destroying the choice
            # buttons: removing the focused widget would otherwise trigger a
            # focus rewind mid-teardown (the button is already detached, so its
            # `window` is gone). `restore_focus` alone isn't enough — there may
            # be no saved focus — so anchor on the (now-shown) OK button.
            @ok.show
            @cancel.show
            @ok.focus
            bb.destroy
            window.restore_focus
            done(idx >= 0 ? Code::Accepted : Code::Rejected)
            # -1 is the internal "dismissed" sentinel (drives the reject code
            # above); the public block sees `nil` for a dismissal, a real index
            # otherwise.
            blk.call(idx >= 0 ? idx : nil)
            update!
          end
        end

        buttons.each_with_index do |b, i|
          b.on(Crysterm::Event::Clicked) { finish.call i }
        end

        @ask_keys.on(window, Crysterm::Event::KeyPress) do |e|
          case e.key
          when Tput::Key::Left
            next if buttons.empty? # nothing to move between (and `% 0` would crash)
            cur = (cur - 1) % buttons.size
            buttons[cur].focus
            e.accept
            update!
          when Tput::Key::Right
            next if buttons.empty?
            cur = (cur + 1) % buttons.size
            buttons[cur].focus
            e.accept
            update!
          when Tput::Key::Escape
            e.accept
            finish.call -1
          end
        end

        window.save_focus
        buttons[cur]?.try &.focus
        update!
      end

      # Shared prelude of both question forms. A question's button row is
      # anchored to the *frame* (bottom-right), so the box cannot also shrink to
      # its text the way a plain notification does — the buttons would be pushed
      # outside it. Turning the notification default off here keeps one class
      # honest for both jobs; re-enable with `shrink_to_fit = true` if a caller
      # really wants it.
      private def begin_question : Nil
        self.shrink_to_fit = false
      end

      # ---- Dismissal -----------------------------------------------------------

      # Removes the keypress-dismiss subscription (armed on the *window* by a
      # timeout-less notification `#open`) and any pending question before
      # teardown: otherwise the next keypress runs `end_it`/`finish` against the
      # destroyed widget — hiding it, re-rendering, and possibly yanking focus in
      # the rebuilt UI.
      def destroy
        @ev_keypress.off
        # Drop the question accelerator via its captured window — safe here
        # (still attached) and after detach alike.
        @ask_keys.off
        # Run the OK/Cancel teardown while `window?` is still valid; `super`
        # detaches us, and `teardown_ok_cancel` needs the window for
        # `restore_focus`.
        window?.try { teardown_ok_cancel @ev_ok, @ev_cancel }
        # Invalidate any armed *timed* dismissal fiber too, so its `end_it`
        # no-ops rather than firing against the torn-down widget.
        bump_dismiss_gen
        # Nothing may dismiss the box any more, so holding the callbacks would
        # only pin the closures to a dead widget.
        @dismiss_callback = nil
        @ask_block = nil
        @ask_choices_block = nil
        super
      end

      # Dismisses a notification and runs *callback*. Internal: the generation
      # counter *gen* is the notification `#open`'s stale-fiber guard, not
      # something a caller can meaningfully supply — dismiss from outside with
      # `#accept`.
      protected def end_it(gen : Int32? = nil, &callback : Proc(Nil))
        # A stale timer/keypress fiber from a superseded `#open` captured an
        # older generation; ignore it so it can't dismiss a newer message early.
        return if gen && !dismiss_current?(gen)
        if scrollable?
          begin
            window.restore_focus
          rescue
          end
        end
        @dismiss_callback = nil
        # A notification has only an acknowledgement, so any dismissal — key,
        # timeout or `#accept` — is the affirmative outcome.
        done Code::Accepted
        callback.try &.call
      end

      # Whether a question form is currently awaiting an answer.
      private def question_pending? : Bool
        !(@ask_block.nil? && @ask_choices_block.nil?)
      end

      # Dismisses a notification programmatically, exactly as a keypress/timeout
      # would: restores focus, runs the pending callback, and closes with
      # `Code::Accepted`. Also invalidates any armed dismissal fiber, so it can't
      # fire the callback a second time. With a question outstanding this is the
      # plain `Dialog#accept` instead — the question's own wiring reports the
      # answer.
      def accept : Nil
        return super if question_pending?
        @ev_keypress.off
        cb = @dismiss_callback
        bump_dismiss_gen
        end_it { cb.try &.call }
      end

      # :ditto: a notification has no negative outcome to report — dismissing it
      # *is* acknowledging it — so Escape/Cancel resolves the same way as
      # `#accept`. A pending question keeps the real `Dialog#reject`.
      def reject : Nil
        return super if question_pending?
        accept
      end

      # ---- Severity presets ----------------------------------------------------

      # Severity of a message, mirroring Qt's `QMessageBox` icons. Each maps
      # to a colored leading glyph drawn before the text by `#open_with`.
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
      def open_with(severity : Severity, text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        open("#{severity.prefix(glyph_tier)}#{text}", time, &callback)
      end

      def information(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        open_with(Severity::Information, text, time, &callback)
      end

      def warning(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        open_with(Severity::Warning, text, time, &callback)
      end

      def critical(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        open_with(Severity::Critical, text, time, &callback)
      end

      def question(text, time : Time::Span? = Crysterm::Config.message_display_time, &callback : Proc(Nil))
        open_with(Severity::Question, text, time, &callback)
      end

      # ---- One-call class presenters -------------------------------------------

      # Static one-call helper ↔ `QMessageBox::information`: builds a `MessageBox`
      # centered on *window*, shows *text* with the info icon, and returns it —
      # the canonical way to pop a message box in one line. *callback* (optional)
      # runs on dismissal; any other keyword (`width:`, `height:`, `style:`, …)
      # is forwarded to `.new`, overriding the centered placement default.
      #
      # ```
      # Crysterm::Widget::MessageBox.information window, "Saved."
      # ```
      def self.information(window : ::Crysterm::Window, text, *, time : Time::Span? = Crysterm::Config.message_display_time, callback : Proc(Nil)? = nil, **opts) : MessageBox
        popup Severity::Information, window, text, time, callback, opts
      end

      # :ditto: — warning icon ↔ `QMessageBox::warning`.
      def self.warning(window : ::Crysterm::Window, text, *, time : Time::Span? = Crysterm::Config.message_display_time, callback : Proc(Nil)? = nil, **opts) : MessageBox
        popup Severity::Warning, window, text, time, callback, opts
      end

      # :ditto: — critical icon ↔ `QMessageBox::critical`.
      def self.critical(window : ::Crysterm::Window, text, *, time : Time::Span? = Crysterm::Config.message_display_time, callback : Proc(Nil)? = nil, **opts) : MessageBox
        popup Severity::Critical, window, text, time, callback, opts
      end

      # :ditto: — question icon ↔ `QMessageBox::question`. This is the *notice*
      # form (icon + timed dismissal); for the interactive yes/no box use
      # `.ask`.
      def self.question(window : ::Crysterm::Window, text, *, time : Time::Span? = Crysterm::Config.message_display_time, callback : Proc(Nil)? = nil, **opts) : MessageBox
        popup Severity::Question, window, text, time, callback, opts
      end

      # Static one-call presenter ↔ `QMessageBox::question` (the interactive
      # form): builds a `MessageBox` centered on *window* and sized to *text*,
      # asks it, and returns the dialog. The block receives the yes/no answer.
      # Any keyword (`width:`, `ok_text:`, `style:`, …) is forwarded to `.new`,
      # overriding the computed defaults.
      #
      # ```
      # Crysterm::Widget::MessageBox.ask(window, "Delete this file?") { |yes| ... }
      # ```
      def self.ask(window : ::Crysterm::Window, text : String, **opts, &block : Bool ->) : MessageBox
        q = new(**::Crysterm::Mixin::OkCancelDialog.presenter_geometry(window, text).merge(opts))
        q.open(text, &block)
        q
      end

      # Shared builder for the static severity helpers: centers a fresh
      # `MessageBox` on *window* (unless *opts* override placement), displays
      # *text* with the severity prefix, and returns it.
      private def self.popup(severity : Severity, window : ::Crysterm::Window, text, time : Time::Span?, callback : Proc(Nil)?, opts) : MessageBox
        merged = {parent: window, top: "center", left: "center"}.merge(opts)
        msg = new(**merged)
        msg.open_with(severity, text, time) { callback.try &.call }
        msg
      end
    end
  end
end
