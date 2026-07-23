require "./dialog"

module Crysterm
  class Widget
    # Question element
    #
    # <!-- widget-examples:capture v1 -->
    # ![Question screenshot](../../tests/widget/question/question.5s.apng)
    # <!-- /widget-examples:capture -->
    class Question < Dialog
      include ::Crysterm::Mixin::OkCancelDialog

      property text : String = ""

      # TODO Positioning is bad for buttons.
      # Use a layout for buttons.
      # Also, make unlimited number of buttons/choices possible.

      @ok : Button = ::Crysterm::Mixin::OkCancelDialog.ok_button(top: 4, left: 1, width: 6)
      @cancel : Button = ::Crysterm::Mixin::OkCancelDialog.cancel_button(top: 4, left: 8, width: 8)

      # Pending-`ask` state, reachable from `#destroy` so a dialog torn down
      # while an answer is outstanding leaves nothing on the window.
      #
      # `@ask_keys` is the window-level `KeyPress` accelerator: a `Subscription`
      # captures the window it was installed on, so `#off` works even after the
      # dialog has detached (where `window?` is already nil) — unlike a raw
      # `window.on` handle, whose removal would need a live `window` and raise
      # post-destroy.
      @ask_keys = ::Crysterm::Subscription.new

      # The OK/Cancel `Pressed` handles, so `#destroy` can run the same
      # `teardown_ok_cancel` the normal `finish` path does.
      @ev_ok : ::EventHandler::Wrapper(::Proc(::Crysterm::Event::Pressed, ::Nil))? = nil
      @ev_cancel : ::EventHandler::Wrapper(::Proc(::Crysterm::Event::Pressed, ::Nil))? = nil

      # The outstanding answer callbacks. Nil whenever no `ask`/`ask_choices` is
      # pending; `finish` nils its own before invoking it (idempotence latch),
      # and `#destroy` nils them so a stray handler can never fire on the dead
      # dialog.
      @ask_block : ::Proc(Bool, ::Nil)? = nil
      @ask_choices_block : ::Proc(Int32?, ::Nil)? = nil

      def initialize(ok_text = nil, cancel_text = nil, **box)
        box["content"]?.try do |c|
          @text = c
        end

        super **box

        # Dialogs start hidden: `ask`/`ask_choices` call `show` to reveal them.
        # Without this the dialog renders on the first frame and stacks with
        # other dialogs on the window.
        hide

        # Custom button labels (Qt lets you relabel the standard buttons).
        ok_text.try { |t| @ok.set_content t }
        cancel_text.try { |t| @cancel.set_content t }

        append @ok
        append @cancel
      end

      # Asks *text* and delivers the yes/no answer to *block* — the block-based
      # sugar over the `Dialog` result protocol: an affirmative answer closes
      # with `Code::Accepted` (`Event::Accepted`), a negative one with
      # `Code::Rejected` (`Event::Rejected`), and `Event::Finished` follows
      # either way.
      def ask(text = nil, &block : Bool ->)
        set_content text || @text
        # On top with the modal grab taken (`Dialog#show_modal`), so widgets
        # beneath the open dialog aren't clickable; every close path runs
        # `#done`, which releases the grab.
        show_modal
        @result = Code::Rejected.to_i

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
            request_render
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

        ev_ok = @ev_ok = @ok.on(Crysterm::Event::Pressed) do
          finish.call true
        end

        ev_cancel = @ev_cancel = @cancel.on(Crysterm::Event::Pressed) do
          finish.call false
        end

        window.save_focus
        focus

        request_render
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
      def ask_choices(text = nil, choices : Array(String) = ["OK", "Cancel"], default = 0, &block : Int32? ->)
        set_content text || @text
        # On top with the modal grab taken (`Dialog#show_modal`), so widgets
        # beneath the open dialog aren't clickable; every close path runs
        # `#done`, which releases the grab.
        show_modal
        @result = Code::Rejected.to_i

        # The fixed OK/Cancel pair is not used in this mode.
        @ok.hide
        @cancel.hide

        # The choice buttons carry `Role::Apply`, so the box emits no
        # accept/reject signal — each choice's meaning is its index, wired on its
        # own `Pressed` below.
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
            request_render
          end
        end

        buttons.each_with_index do |b, i|
          b.on(Crysterm::Event::Pressed) { finish.call i }
        end

        @ask_keys.on(window, Crysterm::Event::KeyPress) do |e|
          case e.key
          when Tput::Key::Left
            next if buttons.empty? # nothing to move between (and `% 0` would crash)
            cur = (cur - 1) % buttons.size
            buttons[cur].focus
            e.accept
            request_render
          when Tput::Key::Right
            next if buttons.empty?
            cur = (cur + 1) % buttons.size
            buttons[cur].focus
            e.accept
            request_render
          when Tput::Key::Escape
            e.accept
            finish.call -1
          end
        end

        window.save_focus
        buttons[cur]?.try &.focus
        request_render
      end

      # Tears down a pending `ask`/`ask_choices` before the dialog goes away.
      #
      # Without this, the window-level `KeyPress` accelerator survives on the
      # live window holding the dead dialog: a later unconsumed
      # Enter/Escape/'q'/'y'/'n' anywhere in the app would be swallowed
      # (permanently, once the done-latch trips) and `finish` would run against
      # the destroyed widget (`window.restore_focus` raising on the way).
      def destroy
        # Drop the accelerator via its captured window — safe here (still
        # attached) and after detach alike.
        @ask_keys.off
        # Run the OK/Cancel teardown while `window?` is still valid; `super`
        # detaches us, and `teardown_ok_cancel` needs the window for
        # `restore_focus`.
        window?.try { teardown_ok_cancel @ev_ok, @ev_cancel }
        # Null the pending callbacks so no stray delivery can invoke them on the
        # dead dialog.
        @ask_block = nil
        @ask_choices_block = nil
        super
      end
    end
  end
end
