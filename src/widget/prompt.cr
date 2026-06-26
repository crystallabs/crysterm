require "./dialog"

module Crysterm
  class Widget
    # <!-- widget-examples:capture v1 -->
    # ![Prompt screenshot](../../examples/widget/prompt/prompt-capture5s.apng)
    # <!-- /widget-examples:capture -->
    class Prompt < Dialog
      include ::Crysterm::Mixin::OkCancelDialog

      property text : String = ""

      # Optional validator (Qt's `QLineEdit` validator / `QInputDialog`
      # acceptance). Given the entered text, it returns whether the value is
      # acceptable; on a `false` the dialog stays open for the user to correct
      # the input instead of submitting. `nil` accepts anything.
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
        # The prompt drives reading explicitly via `#read_input`; leaving
        # `input_on_focus` on would auto-start a read (with no callback) the
        # moment the field is focused, swallowing the real read's callback.
        input_on_focus: false,
      )

      @ok : Button = ::Crysterm::Mixin::OkCancelDialog.ok_button(top: 5, left: 2, width: 6)
      @cancel : Button = ::Crysterm::Mixin::OkCancelDialog.cancel_button(top: 5, left: 10, width: 8)

      def initialize(secret = nil, censor = nil, placeholder = nil, validator = nil, **box)
        box["content"]?.try do |c|
          @text = c
        end

        super **box

        # Dialogs start hidden, like Blessed's `options.hidden = true`: `read_input`
        # calls `show` to reveal the prompt. Without this the prompt renders on the
        # first frame and, when several dialogs share a screen, they stack on top
        # of each other.
        hide

        # Echo mode (Qt `QLineEdit::EchoMode`): hide the typed text entirely
        # (`secret`) or mask it with `*` (`censor`), and an optional placeholder.
        secret.try { |v| @textinput.secret = v }
        censor.try { |v| @textinput.censor = v }
        placeholder.try { |v| @textinput.placeholder = v }
        @validator = validator

        append @textinput
        append @ok
        append @cancel
      end

      def read_input(text = nil, value = "", &callback : Proc(String?, String?, Nil))
        set_content text || @text
        show

        @textinput.value = value

        screen.save_focus
        # focus

        # ev_keys = screen.on(Event::KeyPress) do |e|
        #  next unless (e.key == Tput::Key::Enter || e.key == Tput::Key::Escape)
        #  done.call nil, e.key == Tput::Key::Enter
        # end

        ev_ok = @ok.on ::Crysterm::Event::Press, ->on_press_ok(::Crysterm::Event::Press)

        ev_cancel = @cancel.on ::Crysterm::Event::Press, ->on_press_cancel(::Crysterm::Event::Press)

        # Self-referential reader so a rejected (invalid) submit can re-arm the
        # input without closing the dialog.
        reader = uninitialized -> Nil
        reader = -> do
          @textinput.read_input do |err, data|
            # A non-nil `data` is a submit (Enter); validate it. On rejection,
            # keep the dialog open and read again. Cancel (`data == nil`) and
            # accepted values fall through to teardown.
            if !data.nil? && (v = @validator) && !v.call(data)
              reader.call
              next
            end

            teardown_ok_cancel ev_ok, ev_cancel

            callback.try do |c|
              c.call err, data
            end
          end
        end
        reader.call

        request_render
      end

      def on_press_ok(e)
        @textinput.submit
      end

      def on_press_cancel(e)
        @textinput.cancel
      end
    end
  end
end
