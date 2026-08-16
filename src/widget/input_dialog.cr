require "./dialog"

module Crysterm
  class Widget
    # Single-value text entry dialog, modeled after Qt's `QInputDialog`.
    #
    # A body label, one `LineEdit` and the OK/Cancel pair. `#open(text) { |s| … }`
    # presents it and delivers the entered string — or `nil` when cancelled —
    # through the `Dialog` result protocol.
    #
    # ```
    # Widget::InputDialog.read(window, "Name:") { |s| greet s if s }
    # ```
    #
    # Excluded from the DOM-loader registry: self-populating composite
    # (see `Crysterm::DOM::Skip`).
    @[::Crysterm::DOM::Skip]
    # <!-- widget-examples:capture v1 -->
    # ![InputDialog screenshot](../../tests/widget/input_dialog/input_dialog.5s.apng)
    # <!-- /widget-examples:capture -->
    class InputDialog < Dialog
      include ::Crysterm::Mixin::OkCancelDialog

      # The text entry field (Qt's `QInputDialog` line edit). Exposed so callers
      # can configure echo mode / placeholder directly, and for testing.
      getter line_edit = LineEdit.new(
        top: 3,
        height: 1,
        left: 2,
        right: 2,
        # `#open` drives reading explicitly; `input_on_focus` would auto-start a
        # callback-less read on focus, swallowing the real callback.
        input_on_focus: false,
      )

      # Bottom-right anchored (see `OkCancelDialog.ok_button`); the `#line_edit`
      # above sits at `top: 3`, so on the default height-7 dialog the buttons land
      # on the last interior row.
      @ok : Button = ::Crysterm::Mixin::OkCancelDialog.ok_button
      @cancel : Button = ::Crysterm::Mixin::OkCancelDialog.cancel_button

      def initialize(echo_mode : LineEdit::EchoMode? = nil, placeholder_text = nil, validator = nil, **box)
        super **box

        # Dialogs start hidden; `#open` calls `show`. Otherwise the dialog
        # renders on the first frame, and dialogs sharing a window stack up.
        hide

        echo_mode.try { |v| @line_edit.echo_mode = v }
        placeholder_text.try { |v| @line_edit.placeholder_text = v }
        validator.try { |v| @line_edit.validator = v }

        append @line_edit
        append @ok
        append @cancel
      end

      # The field's acceptance predicate (Qt's `QLineEdit` validator), which now
      # lives on the field itself — this is a straight delegation so a dialog
      # can still be configured in one line.
      def validator : Proc(String, Bool)?
        @line_edit.validator
      end

      # :ditto:
      def validator=(v : Proc(String, Bool)?) : Proc(String, Bool)?
        @line_edit.validator = v
      end

      # Static one-call presenter ↔ `QInputDialog::getText`: builds an
      # `InputDialog` centered on *window* and sized to *text*, starts reading,
      # and returns the dialog. The block receives the entered string, or `nil`
      # when cancelled. Any keyword (`width:`, `echo_mode:`, `validator:`, …) is
      # forwarded to `.new`, overriding the computed defaults.
      #
      # ```
      # Crysterm::Widget::InputDialog.read(window, "Name:") { |s| ... }
      # ```
      def self.read(window : ::Crysterm::Window, text : String, value = "", **opts, &callback : String? ->) : InputDialog
        p = new(**::Crysterm::Mixin::OkCancelDialog.presenter_geometry(window, text).merge(opts))
        p.open(text, value, &callback)
        p
      end

      # Prompts with *text* (starting the field at *value*) and delivers the
      # entered string — or `nil` when cancelled — to *callback*. Block-based
      # sugar over the `Dialog` result protocol: a submitted value closes with
      # `Code::Accepted` (`Event::Accepted`), a cancel with `Code::Rejected`
      # (`Event::Rejected`); `Event::Finished` follows either way.
      #
      # A `#validator` that rejects the entry keeps the dialog open: the field's
      # own `#submit` refuses to finish the read, so nothing here has to re-arm
      # the reader.
      def open(text = nil, value = "", &callback : String? ->)
        # `begin_modal_content` shows the dialog modally (an invalid submit
        # leaves the read running, correctly keeping the grab).
        begin_modal_content text

        @line_edit.value = value

        window.save_focus

        ev_ok = @ok.on(::Crysterm::Event::Clicked) { accept }

        ev_cancel = @cancel.on(::Crysterm::Event::Clicked) { reject }

        @line_edit.read_input do |data|
          teardown_ok_cancel ev_ok, ev_cancel
          # Record the outcome before the callback runs, so both see the same
          # `#result`.
          done(data ? Code::Accepted : Code::Rejected)

          callback.try do |c|
            c.call data
          end
        end

        update!
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
