module Crysterm
  module Mixin
    # Shared pieces for the simple modal dialogs that present a fixed
    # "OK"/"Cancel" button pair: button construction and modal teardown.
    #
    # The including widget declares `@ok`/`@cancel` buttons (typically via
    # `.ok_button`/`.cancel_button`) and calls `#teardown_ok_cancel` when the
    # dialog closes.
    module OkCancelDialog
      # Builds a single-row, centered dialog `Button` labelled *content* at the
      # given position/size. The *focus_on_click*/*shrink_to_fit* defaults match
      # `Button`'s own; callers override where their style differs.
      def self.dialog_button(
        content : String, width,
        *,
        top = nil, left = nil, right = nil, bottom = nil,
        parent = nil,
        focus_on_click : Bool = true,
        shrink_to_fit : Bool = false,
      ) : ::Crysterm::Widget::Button
        ::Crysterm::Widget::Button.new(
          parent: parent,
          top: top,
          left: left,
          right: right,
          bottom: bottom,
          width: width,
          height: 1,
          shrink_to_fit: shrink_to_fit,
          content: content,
          align: :center,
          focus_on_click: focus_on_click,
        )
      end

      # Builds the affirmative ("OK") dialog button at *top*/*left* with the
      # shared single-row, centered, not-focus-on-click style.
      def self.ok_button(top, left, width = 6) : ::Crysterm::Widget::Button
        dialog_button "OK", width, top: top, left: left, focus_on_click: false, shrink_to_fit: true
      end

      # Builds the negative ("Cancel") dialog button (see `.ok_button` for the
      # shared style).
      def self.cancel_button(top, left, width = 8) : ::Crysterm::Widget::Button
        dialog_button "Cancel", width, top: top, left: left, focus_on_click: false, shrink_to_fit: true
      end

      # Standard modal teardown: hide, restore the focus saved when opened, and
      # unregister the OK/Cancel `Pressed` handlers (*ev_ok*/*ev_cancel* may each
      # be nil if never registered).
      protected def teardown_ok_cancel(ev_ok, ev_cancel) : Nil
        hide
        window.restore_focus
        ev_ok.try { |h| @ok.off ::Crysterm::Event::Pressed, h }
        ev_cancel.try { |h| @cancel.off ::Crysterm::Event::Pressed, h }
      end
    end
  end
end
