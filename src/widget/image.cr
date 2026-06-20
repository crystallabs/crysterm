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
    # Both backends are now implemented. As in Blessed, the default is `:ansi`
    # (the dependency-free, fully portable backend that draws into the cell
    # grid). Pass `type: Overlay` for the w3m true-color overlay instead.
    #
    # ```
    # img = Widget::Image.new file: "picture.png", parent: screen
    # # => Widget::ANSIImage
    #
    # img = Widget::Image.new file: "picture.png", type: Widget::Image::Type::Overlay, parent: screen
    # # => Widget::OverlayImage
    # ```
    module Image
      # Backend used to render the image.
      enum Type
        Ansi    # ANSI-cell approximation, drawn into the cell grid (`ANSIImage`)
        Overlay # w3m true-color overlay (`OverlayImage`)
      end

      # Builds the concrete image widget for *type*, forwarding all remaining
      # options to its constructor.
      def self.new(*, type : Type = Type::Ansi, **opts) : ANSIImage | OverlayImage
        case type
        in Type::Overlay
          OverlayImage.new **opts
        in Type::Ansi
          ANSIImage.new **opts
        end
      end
    end
  end
end
