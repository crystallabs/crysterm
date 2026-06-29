module Crysterm
  module Mixin
    # Shared pieces for the two simple modal dialogs that present a fixed
    # "Okay"/"Cancel" button pair — `Widget::Prompt` and `Widget::Question`.
    #
    # Both hand-built the identical buttons (same single-row, centered,
    # not-focus-on-click style, differing only in position) and both hand-rolled
    # the same modal teardown: hide the dialog, restore the focus saved at open
    # time, and unregister the OK/Cancel `Press` handlers. That is centralized
    # here.
    #
    # The including widget declares `@ok`/`@cancel` buttons (typically via
    # `.ok_button`/`.cancel_button`) and calls `#teardown_ok_cancel` when the
    # dialog closes.
    module OkCancelDialog
      # Builds a dialog button labelled *content* at *top*/*left*/*width* with the
      # shared single-row, centered, not-focus-on-click style — the identical
      # `Button` construction the OK and Cancel builders otherwise repeat (they
      # differ only in label and default width).
      private def self.dialog_button(top, left, width, content : String) : ::Crysterm::Widget::Button
        ::Crysterm::Widget::Button.new(
          top: top,
          left: left,
          width: width,
          height: 1,
          resizable: true,
          content: content,
          align: :center,
          focus_on_click: false,
        )
      end

      # Builds the affirmative ("Okay") dialog button at *top*/*left* with the
      # shared single-row, centered, not-focus-on-click style.
      def self.ok_button(top, left, width = 6) : ::Crysterm::Widget::Button
        dialog_button top, left, width, "Okay"
      end

      # Builds the negative ("Cancel") dialog button (see `.ok_button` for the
      # shared style).
      def self.cancel_button(top, left, width = 8) : ::Crysterm::Widget::Button
        dialog_button top, left, width, "Cancel"
      end

      # Standard modal teardown shared by both dialogs: hide the dialog, restore
      # the focus saved when it opened, and unregister the OK/Cancel `Press`
      # handlers (*ev_ok*/*ev_cancel*, either of which may be nil if it was never
      # registered).
      protected def teardown_ok_cancel(ev_ok, ev_cancel) : Nil
        hide
        window.restore_focus
        ev_ok.try { |h| @ok.off ::Crysterm::Event::Press, h }
        ev_cancel.try { |h| @cancel.off ::Crysterm::Event::Press, h }
      end
    end
  end
end
