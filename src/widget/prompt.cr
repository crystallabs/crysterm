require "./dialog"

module Crysterm
  class Widget
    # Excluded from the DOM-loader registry: self-populating composite
    # (see `Crysterm::DOM::Skip`).
    @[::Crysterm::DOM::Skip]
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

      # The text entry field (Qt's `QInputDialog` line edit). Exposed so callers
      # can configure echo mode / placeholder directly, and for testing.
      getter line_edit = LineEdit.new(
        top: 3,
        height: 1,
        left: 2,
        right: 2,
        # `#read_input` drives reading explicitly; `input_on_focus` would
        # auto-start a callback-less read on focus, swallowing the real callback.
        input_on_focus: false,
      )

      # Bottom-right anchored (see `OkCancelDialog.ok_button`); the `#line_edit`
      # above sits at `top: 3`, so on the default height-7 dialog the buttons land
      # on the last interior row.
      @ok : Button = ::Crysterm::Mixin::OkCancelDialog.ok_button
      @cancel : Button = ::Crysterm::Mixin::OkCancelDialog.cancel_button

      def initialize(echo_mode : LineEdit::EchoMode? = nil, placeholder_text = nil, validator = nil, **box)
        box["content"]?.try do |c|
          @text = c
        end

        super **box

        # Dialogs start hidden; `#read_input` calls `show`. Otherwise the prompt
        # renders on the first frame, and dialogs sharing a window stack up.
        hide

        echo_mode.try { |v| @line_edit.echo_mode = v }
        placeholder_text.try { |v| @line_edit.placeholder_text = v }
        @validator = validator

        append @line_edit
        append @ok
        append @cancel
      end

      # Static one-call presenter ↔ `QInputDialog::getText`: builds a `Prompt`
      # centered on *window* and sized to *text*, starts reading, and returns
      # the dialog. The block receives the entered string, or `nil` when
      # cancelled. Any keyword (`width:`, `echo_mode:`, `validator:`, …) is
      # forwarded to `.new`, overriding the computed defaults.
      #
      # ```
      # Crysterm::Widget::Prompt.read(window, "Name:") { |s| ... }
      # ```
      def self.read(window : ::Crysterm::Window, text : String, value = "", **opts, &callback : String? ->) : Prompt
        p = new(**::Crysterm::Mixin::OkCancelDialog.presenter_geometry(window, text).merge(opts))
        p.read_input(text, value, &callback)
        p
      end

      # Prompts with *text* (starting the field at *value*) and delivers the
      # entered string — or `nil` when cancelled — to *callback*. Block-based
      # sugar over the `Dialog` result protocol: a submitted value closes with
      # `Code::Accepted` (`Event::Accepted`), a cancel with `Code::Rejected`
      # (`Event::Rejected`); `Event::Finished` follows either way.
      def read_input(text = nil, value = "", &callback : String? ->)
        # `begin_modal_content` shows the dialog modally (an invalid submit
        # re-arms the reader without closing, correctly keeping the grab).
        begin_modal_content text

        @line_edit.value = value

        window.save_focus

        ev_ok = @ok.on(::Crysterm::Event::Clicked) { accept }

        ev_cancel = @cancel.on(::Crysterm::Event::Clicked) { reject }

        # Self-referential reader so a rejected (invalid) submit can re-arm the
        # input without closing the dialog.
        reader = uninitialized -> Nil
        reader = -> do
          @line_edit.read_input do |data|
            # Non-nil `data` is a submit (Enter); validate and re-read on
            # rejection. Cancel (`data == nil`) and accepted values fall through.
            if !data.nil? && (v = @validator) && !v.call(data)
              reader.call
              next
            end

            teardown_ok_cancel ev_ok, ev_cancel
            # Record the outcome before the callback runs, so both see the same
            # `#result`.
            done(data ? Code::Accepted : Code::Rejected)

            callback.try do |c|
              c.call data
            end
          end
        end
        reader.call

        request_render
      end

      # The affirmative gesture submits the embedded field rather than closing
      # outright: the field's own read callback carries the entered value, runs
      # the `#validator`, and closes the dialog from there. Closing here
      # directly would discard the text.
      def accept : Nil
        @line_edit.submit
      end

      # :ditto: the negative gesture cancels the field, whose read callback then
      # closes the dialog with `Code::Rejected`.
      def reject : Nil
        @line_edit.cancel
      end
    end
  end
end
