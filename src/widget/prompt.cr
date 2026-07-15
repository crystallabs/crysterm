require "./dialog"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![Prompt screenshot](../../tests/widget/prompt/prompt.5s.apng)
    # <!-- /widget-examples:capture -->
    class Prompt < Dialog
      include ::Crysterm::Mixin::OkCancelDialog

      property text : String = ""

      # Optional validator (Qt's `QLineEdit` validator / `QInputDialog`
      # acceptance). Returns whether the entered text is acceptable; on `false`
      # the dialog stays open instead of submitting. `nil` accepts anything.
      property validator : Proc(String, Bool)? = nil

      # TODO Positioning is bad for buttons.
      # Use a layout for buttons.
      # Also, make unlimited number of buttons/choices possible.

      # The text entry field (Qt's `QInputDialog` line edit). Exposed so callers
      # can configure echo mode / placeholder directly, and for testing.
      getter textinput = LineEdit.new(
        top: 3,
        height: 1,
        left: 2,
        right: 2,
        # `#read_input` drives reading explicitly; `input_on_focus` would
        # auto-start a callback-less read on focus, swallowing the real callback.
        input_on_focus: false,
      )

      @ok : Button = ::Crysterm::Mixin::OkCancelDialog.ok_button(top: 5, left: 2, width: 6)
      @cancel : Button = ::Crysterm::Mixin::OkCancelDialog.cancel_button(top: 5, left: 10, width: 8)

      def initialize(echo_mode : LineEdit::EchoMode? = nil, placeholder_text = nil, validator = nil, **box)
        box["content"]?.try do |c|
          @text = c
        end

        super **box

        # Dialogs start hidden, like Blessed's `options.hidden = true`: `read_input`
        # calls `show` to reveal the prompt. Otherwise it renders on the first
        # frame and, with several dialogs sharing a window, they stack up.
        hide

        # Echo mode (`LineEdit::EchoMode`, Qt's `QLineEdit::EchoMode`): hide the
        # text entirely (`NoEcho`) or mask it (`Password`), plus an optional
        # placeholder.
        echo_mode.try { |v| @textinput.echo_mode = v }
        placeholder_text.try { |v| @textinput.placeholder_text = v }
        @validator = validator

        append @textinput
        append @ok
        append @cancel
      end

      # Prompts with *text* (starting the field at *value*) and delivers the
      # entered string — or `nil` when cancelled — to *callback*. Block-based
      # sugar over the `Dialog` result protocol: a submitted value closes with
      # `Code::Accepted` (`Event::Accepted`), a cancel with `Code::Rejected`
      # (`Event::Rejected`); `Event::Finished` follows either way.
      def read_input(text = nil, value = "", &callback : Proc(String?, String?, Nil))
        set_content text || @text
        show
        @result = Code::Rejected.to_i

        @textinput.value = value

        window.save_focus
        # focus

        # ev_keys = window.on(Event::KeyPress) do |e|
        #  next unless (e.key == Tput::Key::Enter || e.key == Tput::Key::Escape)
        #  done.call nil, e.key == Tput::Key::Enter
        # end

        # The buttons are just the two dialog gestures (which drive the embedded
        # field — see `#accept`/`#reject`), so they wire straight to them rather
        # than to a pair of near-identical relay methods.
        ev_ok = @ok.on(::Crysterm::Event::Press) { accept }

        ev_cancel = @cancel.on(::Crysterm::Event::Press) { reject }

        # Self-referential reader so a rejected (invalid) submit can re-arm the
        # input without closing the dialog.
        reader = uninitialized -> Nil
        reader = -> do
          @textinput.read_input do |err, data|
            # Non-nil `data` is a submit (Enter); validate and re-read on
            # rejection. Cancel (`data == nil`) and accepted values fall through.
            if !data.nil? && (v = @validator) && !v.call(data)
              reader.call
              next
            end

            teardown_ok_cancel ev_ok, ev_cancel
            # Record the outcome and signal it (`Accepted`/`Rejected` +
            # `Finished`) before the callback runs, so both see the same
            # `#result`.
            done(data ? Code::Accepted : Code::Rejected)

            callback.try do |c|
              c.call err, data
            end
          end
        end
        reader.call

        request_render
      end

      # The affirmative gesture submits the embedded field rather than closing
      # outright: the field's own read callback is what carries the entered
      # value (and runs the `#validator`), and it closes the dialog through
      # `Dialog#done` from there. Closing here directly would discard the text.
      def accept : Nil
        @textinput.submit
      end

      # :ditto: the negative gesture cancels the field, whose read callback then
      # closes the dialog with `Code::Rejected`.
      def reject : Nil
        @textinput.cancel
      end
    end
  end
end
