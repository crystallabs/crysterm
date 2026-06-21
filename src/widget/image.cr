module Crysterm
  class Widget
    # Factory for image widgets, ported from Blessed's `image` element.
    #
    # In Blessed, `image` is a thin dispatcher that constructs one of several
    # concrete image widgets depending on `type`. Crystal can't mutate an
    # object's class at runtime the way Blessed does, so here `Image` is a
    # factory: `Image.new` returns the concrete widget for the requested `type`
    # and forwards all other options to it.
    #
    # The backends are organized by how the image's pixels reach the screen —
    # which is what determines the rendering/erase machinery each one needs:
    #
    # * **cell-grid** — the image becomes character cells Crysterm owns and
    #   diffs: `Ansi` (`ANSIImage`) and `Glyph` (`GlyphImage`, sub-cell glyphs).
    # * **screen-owns-pixels (in the VT window)** — the terminal (or an external
    #   helper) owns the pixels; the widget tracks its cell rectangle and
    #   force-erases on move/hide: `Overlay` (`OverlayImage`, w3mimgdisplay),
    #   `Sixel` (`SixelImage`), `Regis` (`RegisImage`), and `Kitty`
    #   (`KittyImage`, the Kitty graphics protocol).
    # * **separate window** — the terminal renders into another window entirely:
    #   `Tek` (`TekImage`, Tektronix 4014).
    #
    # ```
    # img = Widget::Image.new file: "picture.png", parent: screen # => ANSIImage
    # img = Widget::Image.new file: "picture.png", type: Widget::Image::Type::Sixel, parent: screen
    # ```
    #
    # The factory forwards a single common option bag (`file`, position, size) to
    # whichever backend is selected; backend-specific options (e.g. GlyphImage's
    # `mode`, SixelImage's `dither`) are best passed by constructing the concrete
    # widget directly.
    module Image
      # Backend used to render the image. See the families described above.
      enum Type
        Ansi    # cell-grid, one cell per pixel (`ANSIImage`)
        Glyph   # cell-grid, sub-cell Unicode glyphs (`GlyphImage`)
        Overlay # screen-owns-pixels, external w3mimgdisplay overlay (`OverlayImage`)
        Sixel   # screen-owns-pixels, in-band sixel graphics (`SixelImage`)
        Regis   # screen-owns-pixels, in-band ReGIS vector graphics (`RegisImage`)
        Kitty   # screen-owns-pixels, in-band Kitty graphics protocol (`KittyImage`)
        Tek     # separate window, Tektronix 4014 vectors (`TekImage`)
      end

      alias Any = ANSIImage | GlyphImage | OverlayImage | SixelImage | RegisImage | KittyImage | TekImage

      # Builds the concrete image widget for *type*, forwarding all remaining
      # options to its constructor.
      def self.new(*, type : Type = Type::Ansi, **opts) : Any
        case type
        in Type::Ansi    then ANSIImage.new **opts
        in Type::Glyph   then GlyphImage.new **opts
        in Type::Overlay then OverlayImage.new **opts
        in Type::Sixel   then SixelImage.new **opts
        in Type::Regis   then RegisImage.new **opts
        in Type::Kitty   then KittyImage.new **opts
        in Type::Tek     then TekImage.new **opts
        end
      end
    end
  end
end
