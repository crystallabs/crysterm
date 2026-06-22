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
    #   diffs: `Ansi` (`Image::Ansi`) and `Glyph` (`Image::Glyph`, sub-cell glyphs).
    # * **screen-owns-pixels (in the VT window)** — the terminal (or an external
    #   helper) owns the pixels; the widget tracks its cell rectangle and
    #   force-erases on move/hide: `Overlay` (`Image::Overlay`, w3mimgdisplay) and
    #   `Ueberzug` (`Image::Ueberzug`, the überzug overlay), plus the in-band
    #   `Sixel` (`Image::Sixel`), `Regis` (`Image::Regis`), `Kitty` (`Image::Kitty`,
    #   the Kitty graphics protocol) and `Iterm` (`Image::Iterm`, the iTerm2
    #   inline-images protocol).
    # * **separate window** — the terminal renders into another window entirely:
    #   `Tek` (`Image::Tek`, Tektronix 4014).
    #
    # ```
    # img = Widget::Image.new file: "picture.png", parent: screen # => Image::Ansi
    # img = Widget::Image.new file: "picture.png", type: Widget::Image::Type::Sixel, parent: screen
    # ```
    #
    # The factory forwards a single common option bag (`file`, position, size) to
    # whichever backend is selected; backend-specific options (e.g. Image::Glyph's
    # `mode`, Image::Sixel's `dither`) are best passed by constructing the concrete
    # widget directly.
    module Image
      # 4×4 Bayer ordered-dither matrix (values 0..15), shared by the dithering
      # backends (`Image::Sixel`, `Image::Regis`, `Image::Tek`) which each used
      # to carry their own identical copy.
      BAYER_MATRIX = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
      ]

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
        Ansi     # cell-grid, one cell per pixel (`Image::Ansi`)
        Glyph    # cell-grid, sub-cell Unicode glyphs (`Image::Glyph`)
        Overlay  # screen-owns-pixels, external w3mimgdisplay overlay (`Image::Overlay`)
        Ueberzug # screen-owns-pixels, external überzug overlay (`Image::Ueberzug`)
        Sixel    # screen-owns-pixels, in-band sixel graphics (`Image::Sixel`)
        Regis    # screen-owns-pixels, in-band ReGIS vector graphics (`Image::Regis`)
        Kitty    # screen-owns-pixels, in-band Kitty graphics protocol (`Image::Kitty`)
        Iterm    # screen-owns-pixels, in-band iTerm2 inline images (`Image::Iterm`)
        Tek      # separate window, Tektronix 4014 vectors (`Image::Tek`)
      end

      alias Any = Ansi | Glyph | Overlay | Ueberzug |
                  Sixel | Regis | Kitty | Iterm | Tek

      # The default backend when `type:` is not given, resolved from the config
      # registry (key `image.backend`, env `CRYSTERM_IMAGE_BACKEND`, CLI
      # `--image-backend`). A concrete value (e.g. `kitty`) is used as-is; the
      # special value `auto` runs `detect_backend`. An unrecognized value falls
      # back to `Ansi`.
      def self.default_type : Type
        backend = Crysterm::Config.image_backend
        return detect_backend if backend == "auto"
        Type.parse?(backend) || Type::Ansi
      end

      # Best-effort terminal-capability detection for `image.backend = auto`,
      # from environment hints alone (this factory has no terminal handle):
      # Kitty when running under Kitty, iTerm2 under iTerm, otherwise the
      # universally-safe cell-grid `Ansi` backend. Detection that needs a live
      # terminal round-trip (e.g. Sixel via a DA1 reply) is intentionally not
      # done here — set `image.backend` explicitly for those.
      def self.detect_backend : Type
        return Type::Kitty if ENV["KITTY_WINDOW_ID"]? || !!ENV["TERM"]?.try(&.includes?("kitty"))
        return Type::Iterm if ENV["TERM_PROGRAM"]? == "iTerm.app"
        Type::Ansi
      end

      # Builds the concrete image widget for *type*, forwarding all remaining
      # options to its constructor. When *type* is omitted it defaults to
      # `default_type` (the `image.backend` config option).
      def self.new(*, type : Type = default_type, **opts) : Any
        case type
        in Type::Ansi     then Ansi.new **opts
        in Type::Glyph    then Glyph.new **opts
        in Type::Overlay  then Overlay.new **opts
        in Type::Ueberzug then Ueberzug.new **opts
        in Type::Sixel    then Sixel.new **opts
        in Type::Regis    then Regis.new **opts
        in Type::Kitty    then Kitty.new **opts
        in Type::Iterm    then Iterm.new **opts
        in Type::Tek      then Tek.new **opts
        end
      end

      # Process-wide decode cache: the same file shown by several widgets (or
      # reloaded) is parsed only once. The decoded `PNGGIF::PNG` holds the
      # full-resolution bitmap + raw frames; every widget derives its sized
      # render from it without mutating it, so the instance is shared read-only.
      @@decode_cache = {} of String => PNGGIF::PNG

      # Decodes *file* (a local path or `http(s)` URL) once, caching the result
      # keyed on path + size + mtime (so an on-disk change invalidates it).
      # Returns `nil` on failure.
      def self.decode(file : String) : PNGGIF::PNG?
        key = file
        unless file =~ /^https?:/
          if info = File.info?(file)
            key = "#{file}\u{0}#{info.size}\u{0}#{info.modification_time.to_unix}"
          end
        end
        if png = @@decode_cache[key]?
          return png
        end
        data : String | Bytes = file
        data = Ansi.fetch(file) if file =~ /^https?:/
        png = PNGGIF::PNG.new(data)
        @@decode_cache[key] = png
        png
      rescue
        nil
      end

      # Empties the decode cache (e.g. to reclaim memory).
      def self.clear_decode_cache
        @@decode_cache.clear
      end
    end
  end
end
