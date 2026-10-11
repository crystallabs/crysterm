require "./box"

module Crysterm
  class Widget
    # Abstract base for widgets with a scrollable viewport, modeled after Qt's
    # `QAbstractScrollArea`.
    #
    # Thin grouping base: scroll machinery lives in `Widget` plus per-widget
    # scrollbar-policy defaults; this only gives the family a shared type.
    # Not interactive on its own — editable members opt in via
    # `Mixin::Interactive`.
    abstract class AbstractScrollArea < Box
      # The band this widget reserves inside its frame, between the padding
      # and the viewport — Qt's `QAbstractScrollArea::viewportMargins()`.
      # Protected as in Qt: a subclass sets it for chrome of its own
      # (`PlainTextEdit`'s line-number gutter); it is not a user-facing
      # spacing knob, that is `Style#padding`. Honored by the base content
      # pipeline (`Widget#base_render`, the shared caret and mouse geometry);
      # `TextEdit`, which paints its document itself, does not read it yet.
      @viewport_margins : Padding = Padding::ZERO

      protected def viewport_margins : Padding
        @viewport_margins
      end

      # :ditto: — Qt's `setViewportMargins()`. The frame insets derived from the
      # old box are dropped and a repaint scheduled; the content re-wraps on
      # that frame, since the wrap width changed with the insets.
      protected def viewport_margins=(margins : Padding) : Padding
        @viewport_margins = margins
        @_frame_insets = nil
        update
        margins
      end
    end
  end
end
