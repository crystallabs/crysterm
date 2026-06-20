module Crysterm
  class Widget
    # Factory for image widgets, ported from Blessed's `image` element.
    #
    # In Blessed, `image` is not a widget of its own but a thin dispatcher that
    # constructs one of two concrete image widgets depending on `type`:
    #
    # * `:overlay` — a true-color image drawn *over* the terminal cells via the
    #   external `w3mimgdisplay` helper (`Widget::OverlayImage`).
    # * `:ansi` — an image approximated with ANSI character cells
    #   (`Widget::ANSIImage`).
    #
    # Crystal can't mutate an object's class at runtime the way Blessed does, so
    # here `Image` is a factory: `Image.new` returns the concrete widget for the
    # requested `type` and forwards all other options to it.
    #
    # Crysterm currently implements only the `:overlay` backend, so that is the
    # default (Blessed defaults to `:ansi`). Requesting `:ansi` raises until an
    # `ANSIImage` widget is ported.
    #
    # ```
    # img = Widget::Image.new file: "picture.png", parent: screen
    # # => Widget::OverlayImage
    # ```
    module Image
      # Backend used to render the image.
      enum Type
        Ansi    # ANSI-cell approximation (not yet implemented in Crysterm)
        Overlay # w3m true-color overlay
      end

      # Builds the concrete image widget for *type*, forwarding all remaining
      # options to its constructor. Returns a `Widget::OverlayImage`.
      #
      # Raises `ArgumentError` for `Type::Ansi`, which has no implementation yet.
      def self.new(*, type : Type = Type::Overlay, **opts)
        case type
        in Type::Overlay
          OverlayImage.new **opts
        in Type::Ansi
          raise ArgumentError.new(
            "Image type `ansi` is not implemented yet in Crysterm; " \
            "pass `type: Widget::Image::Type::Overlay` (the default) " \
            "or use `Widget::OverlayImage` directly."
          )
        end
      end
    end
  end
end
