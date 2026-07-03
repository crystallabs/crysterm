module Crysterm
  module Mixin
    # Shared pieces for the two simple modal dialogs that present a fixed
    # "Okay"/"Cancel" button pair — `Widget::Prompt` and `Widget::Question`.
    #
    # Both duplicated identical button construction (same single-row, centered,
    # not-focus-on-click style, differing only in position) and the same modal
    # teardown (hide, restore saved focus, unregister OK/Cancel `Press`
    # handlers). Centralized here.
    #
    # The including widget declares `@ok`/`@cancel` buttons (typically via
    # `.ok_button`/`.cancel_button`) and calls `#teardown_ok_cancel` when the
    # dialog closes.
    module OkCancelDialog
      # Builds a single-row, centered dialog `Button` labelled *content* at the
      # given position/size. Shared by the dialog-button "family"
      # (`.ok_button`/`.cancel_button` below, `DialogButtonBox#make_button`,
      # `Wizard#wizard_button`), which otherwise duplicated this construction
      # differing only in position and the *focus_on_click*/*resizable* flags.
      # Defaults for those two match `Button`'s own class defaults; callers
      # override where their style differs.
      def self.dialog_button(
        content : String, width,
        *,
        top = nil, left = nil, right = nil, bottom = nil,
        parent = nil,
        focus_on_click : Bool = true,
        resizable : Bool = false,
      ) : ::Crysterm::Widget::Button
        ::Crysterm::Widget::Button.new(
          parent: parent,
          top: top,
          left: left,
          right: right,
          bottom: bottom,
          width: width,
          height: 1,
          resizable: resizable,
          content: content,
          align: :center,
          focus_on_click: focus_on_click,
        )
      end

      # Builds the affirmative ("Okay") dialog button at *top*/*left* with the
      # shared single-row, centered, not-focus-on-click style.
      def self.ok_button(top, left, width = 6) : ::Crysterm::Widget::Button
        dialog_button "Okay", width, top: top, left: left, focus_on_click: false, resizable: true
      end

      # Builds the negative ("Cancel") dialog button (see `.ok_button` for the
      # shared style).
      def self.cancel_button(top, left, width = 8) : ::Crysterm::Widget::Button
        dialog_button "Cancel", width, top: top, left: left, focus_on_click: false, resizable: true
      end

      # Standard modal teardown shared by both dialogs: hide, restore the focus
      # saved when opened, and unregister the OK/Cancel `Press` handlers
      # (*ev_ok*/*ev_cancel* may each be nil if never registered).
      protected def teardown_ok_cancel(ev_ok, ev_cancel) : Nil
        hide
        window.restore_focus
        ev_ok.try { |h| @ok.off ::Crysterm::Event::Press, h }
        ev_cancel.try { |h| @cancel.off ::Crysterm::Event::Press, h }
      end
    end
  end
end
