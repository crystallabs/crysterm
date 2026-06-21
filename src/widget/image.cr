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
    #   force-erases on move/hide: `Overlay` (`OverlayImage`, w3mimgdisplay) and
    #   `Ueberzug` (`UeberzugImage`, the überzug overlay), plus the in-band
    #   `Sixel` (`SixelImage`), `Regis` (`RegisImage`), `Kitty` (`KittyImage`,
    #   the Kitty graphics protocol) and `Iterm` (`ItermImage`, the iTerm2
    #   inline-images protocol).
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
      # How an image is fit into a box whose aspect ratio differs from the
      # image's — shared by every backend so the behaviour is consistent.
      enum Fit
        Stretch # fill the box exactly, distorting aspect ratio (default)
        Contain # scale to fit inside the box, letterboxing the remainder
        Cover   # scale to fill the box, cropping the overflow

        # Lays an image of *sw*×*sh* into a *bw*×*bh* box, returning the drawn
        # size and top-left offset `{dw, dh, ox, oy}` (offsets are negative for
        # `Cover`, where the image is larger than the box and gets cropped).
        def layout(bw : Int32, bh : Int32, sw : Int32, sh : Int32) : Tuple(Int32, Int32, Int32, Int32)
          return {bw, bh, 0, 0} if stretch? || sw <= 0 || sh <= 0 || bw <= 0 || bh <= 0
          ar = sw.to_f / sh.to_f
          box_ar = bw.to_f / bh.to_f
          # Pin height (derive width) when the box is "wider" than the image for
          # Contain, or "taller" for Cover; pin width otherwise.
          pin_height = contain? ? (box_ar > ar) : (box_ar < ar)
          if pin_height
            dh = bh
            dw = (bh * ar).round.to_i
          else
            dw = bw
            dh = (dw / ar).round.to_i
          end
          dw = 1 if dw < 1
          dh = 1 if dh < 1
          {dw, dh, (bw - dw) // 2, (bh - dh) // 2}
        end
      end

      # Backend used to render the image. See the families described above.
      enum Type
        Ansi     # cell-grid, one cell per pixel (`ANSIImage`)
        Glyph    # cell-grid, sub-cell Unicode glyphs (`GlyphImage`)
        Overlay  # screen-owns-pixels, external w3mimgdisplay overlay (`OverlayImage`)
        Ueberzug # screen-owns-pixels, external überzug overlay (`UeberzugImage`)
        Sixel    # screen-owns-pixels, in-band sixel graphics (`SixelImage`)
        Regis    # screen-owns-pixels, in-band ReGIS vector graphics (`RegisImage`)
        Kitty    # screen-owns-pixels, in-band Kitty graphics protocol (`KittyImage`)
        Iterm    # screen-owns-pixels, in-band iTerm2 inline images (`ItermImage`)
        Tek      # separate window, Tektronix 4014 vectors (`TekImage`)
      end

      alias Any = ANSIImage | GlyphImage | OverlayImage | UeberzugImage |
                  SixelImage | RegisImage | KittyImage | ItermImage | TekImage

      # Builds the concrete image widget for *type*, forwarding all remaining
      # options to its constructor.
      def self.new(*, type : Type = Type::Ansi, **opts) : Any
        case type
        in Type::Ansi     then ANSIImage.new **opts
        in Type::Glyph    then GlyphImage.new **opts
        in Type::Overlay  then OverlayImage.new **opts
        in Type::Ueberzug then UeberzugImage.new **opts
        in Type::Sixel    then SixelImage.new **opts
        in Type::Regis    then RegisImage.new **opts
        in Type::Kitty    then KittyImage.new **opts
        in Type::Iterm    then ItermImage.new **opts
        in Type::Tek      then TekImage.new **opts
        end
      end
    end
  end
end
