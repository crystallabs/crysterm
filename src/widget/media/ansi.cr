require "../../widget_media_cells"
require "term_colors"

module Crysterm
  class Widget
    # Renders a PNG / APNG / GIF image as colored terminal cells, ported from
    # Blessed's `ansiimage` element.
    #
    # Unlike `Widget::Media::Overlay` (which paints a true-color image over the
    # terminal via the external `w3mimgdisplay` helper), `Media::Ansi` decodes
    # the image itself with the pure-Crystal `PNGGIF::PNG` reader and draws it
    # into the normal cell grid: each downscaled pixel becomes one cell whose
    # background is that pixel's color, portable to any TrueColor terminal with
    # no external dependencies.
    #
    # Because Crysterm renders in TrueColor, pixel RGB values are used directly;
    # there is no 256-color palette-matching step as in Blessed.
    #
    # ```
    # img = Widget::Media::Ansi.new file: "picture.png", width: 30, parent: window
    # ```
    #
    # Animated images (APNG, animated GIF) play automatically unless `animate:
    # false` is passed; `#play`, `#pause` and `#stop` control playback (the
    # animation framework is shared, in `Media::Base`).
    #
    # <!-- widget-examples:capture v1 -->
    # ![Ansi screenshot](../../../tests/widget/media/ansi/ansi.5s.apng)
    # <!-- /widget-examples:capture -->
    class Media::Ansi < Media::Cells
      # Color depth the image is rendered in. Crysterm is natively TrueColor and
      # only reduces colors at output time when the terminal can't do 24-bit; the
      # non-`TrueColor` modes here additionally quantize the pixels themselves to
      # the xterm-256/16/8-color palette, producing the classic low-color look
      # regardless of terminal capability (matching Blessed's `ansiimage` palette-
      # matching portability).
      enum ColorMode
        TrueColor # 24-bit RGB used directly (default)
        C256      # quantized to the xterm 256-color palette
        C16       # quantized to the 16-color ANSI palette
        C8        # quantized to the 8-color base ANSI palette
      end

      # Color depth used to render pixels (see `ColorMode`).
      property colors : ColorMode

      # How pixel colors are dithered when reduced to the `C256`/`C16` palette.
      # Ignored in `ColorMode::TrueColor` (no reduction happens). `Dither::Auto`
      # by default: Floyd–Steinberg for a still, ordered (Bayer) for an animation.
      property dither : Media::Dither = Media::Dither::Auto

      # Scale factor used when neither `width` nor `height` is set on the widget.
      property scale : Float64

      # Render glyphs by luminance (ASCII-art look) instead of solid blocks.
      property? ascii : Bool

      # Terminal cell height-to-width ratio, keeping the image's aspect ratio
      # correct on non-square cells (~2.0 for typical monospace fonts); `1.0`
      # assumes square cells. Changes take effect on the next `#set_image`.
      property cell_aspect : Float64

      def initialize(
        @file = nil,
        @scale : Float64 = 1.0,
        animate : Bool | Timer = true,
        @ascii : Bool = false,
        @speed : Float64 = 1.0,
        # Cell height÷width; defaults to the terminal's measured ratio (CSS
        # layer), not a hardcoded 2:1, so proportions match the real cells.
        @cell_aspect : Float64 = Crysterm::CSS::Length.cell_aspect_ratio,
        @colors : ColorMode = ColorMode::TrueColor,
        @dither : Media::Dither = Media::Dither::Auto,
        @fit : Media::Fit = Media::Fit::Stretch,
        **box,
      )
        # Blessed's `options.shrink = true` equivalent: `resizable` sizes the
        # widget to the image when no explicit width/height is given.
        super(**box.merge(resizable: true))
        setup_animate animate # before set_image, so a shared clock is known when play subscribes

        @file.try { |f| set_image f }

        on(::Crysterm::Event::Destroy) { stop }
      end

      # The decoded image (alias for the shared `#source`), or `nil` if none.
      def img : PNGGIF::PNG?
        source
      end

      # Size the widget to a native-scaled render when no explicit size was given;
      # `#render` then (re)samples to the actual box.
      protected def on_loaded(png : PNGGIF::PNG)
        # Only auto-size an axis the caller left unset. A non-nil size —
        # including a String like "100%"/"50%" — is explicit and must be
        # honored. The old `@width.as?(Int32)` test treated any non-Int as
        # unset, silently replacing a percentage width with the native size.
        return unless @width.nil? || @height.nil?
        native = png.create_cellmap(png.bmp, scale: @scale, cell_aspect: @cell_aspect)
        self.width = (native[0]?.try(&.size) || 0) if @width.nil?
        self.height = native.size if @height.nil?
      end

      # One cell per pixel: sample at the content box size, with cell-aspect
      # correction so the image isn't vertically squashed on tall cells.
      protected def compose(img : PNGGIF::PNG, cols : Int32, rows : Int32, frame : PNGGIF::Bitmap?) : PNGGIF::Bitmap?
        Media::Fitting.compose(img, frame, cols, rows, @fit, @cell_aspect)
      end

      protected def draw_sample(bmp : PNGGIF::Bitmap, xi : Int32, xl : Int32, yi : Int32, yl : Int32)
        lines = window.lines
        # In a reduced-color mode, dither the whole sample to the palette up
        # front (error diffusion needs neighbours, can't be done per cell).
        # Memoized per sample bitmap; unused in TrueColor.
        plane = @colors.true_color? ? nil : @dither_plane_memo.get(bmp) { dither_plane bmp }
        (yi...yl).each do |y|
          cmrow = bmp[y - yi]?
          next unless cmrow
          prow = plane.try &.[y - yi]?
          row = lines[y]?
          next unless row
          (xi...xl).each do |x|
            px = cmrow[x - xi]?
            next unless px
            cell = row[x]?
            next unless cell
            a = px.a / 255.0
            next if a == 0.0 # fully transparent: leave the cell as-is
            rgb = prow ? prow[x - xi] : ((px.r << 16) | (px.g << 8) | px.b)
            paint_cell cell, px, a, rgb
          end
          row.dirty = true
        end
      end

      # Writes one image pixel into a window *cell* (its background *rgb* already
      # palette-reduced for the active mode), blending against the cell's current
      # contents when the pixel is translucent.
      private def paint_cell(cell, px : PNGGIF::Pixel, a : Float64, rgb : Int32)
        if ascii?
          ch, fg = ascii_glyph px, a
          fg = quantize fg
          attr = Attr.pack(0, Attr.pack_color(fg), Attr.pack_color(rgb))
        else
          ch = ' '
          attr = Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(rgb))
        end

        # Composite the image pixel over whatever is currently in the cell.
        blend_cell cell, ch, attr, a
      end

      # Luminance glyphs taken from libcaca (via tng.js).
      DCHARS = "????8@8@#8@8##8#MKXWwz$&%x><\\/xo;+=|^-:i'.`,  `.        "

      # Picks an ASCII glyph + foreground color for *px* (used when `ascii`).
      private def ascii_glyph(px : PNGGIF::Pixel, a : Float64) : Tuple(Char, Int32)
        l = Media.luminance(px) * a / 255.0
        ch = DCHARS[(l * (DCHARS.size - 1)).to_i]
        # Foreground at half intensity, like tng's `fga = 0.5`.
        fg = ((px.r * a * 0.5).to_i << 16) | ((px.g * a * 0.5).to_i << 8) | (px.b * a * 0.5).to_i
        {ch, fg}
      end

      # Memoizes the dithered colour plane for the current `@sample` (the full
      # Floyd–Steinberg/ordered pass is the per-render hot spot, rerun only
      # when the sample bitmap changes — see `SampleMemo`).
      @dither_plane_memo = SampleMemo(Array(Array(Int32))).new

      # Builds a palette-quantized, dithered color plane for the whole sample —
      # one packed RGB per pixel (`-1` for fully transparent). Used only in the
      # reduced-color modes; `paint_cell` reads it instead of quantizing per cell.
      private def dither_plane(bmp : PNGGIF::Bitmap) : Array(Array(Int32))
        ph = bmp.size
        pw = bmp[0]?.try(&.size) || 0
        Media.dither_rgb(bmp, pw, ph, @dither, @animated, -1) do |r, g, b, t|
          rgb = quantize_dither r, g, b, t
          {rgb, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff}
        end
      end

      # The Bayer threshold (±0.5) is scaled to this many color steps before the
      # nearest-palette search — enough to break up banding without obvious
      # cross-hatching on the irregular xterm palette.
      ORDERED_AMP = 48.0

      # Nearest-palette quantization of *r*,*g*,*b*, nudged by the ordered-dither
      # threshold *t* (0.0 for none/diffusion, where the channels are used as-is).
      private def quantize_dither(r : Int32, g : Int32, b : Int32, t : Float64) : Int32
        if t != 0.0
          n = (t * ORDERED_AMP).round.to_i
          r = Media.clamp8(r + n); g = Media.clamp8(g + n); b = Media.clamp8(b + n)
        end
        nearest_palette_rgb r, g, b
      end

      # Quantizes a packed *rgb* to the active palette (`C256`/`C16`), or returns
      # it unchanged in `TrueColor`. Memoized; used for the `ascii` foreground (the
      # cell background is dithered through `dither_plane`).
      private def quantize(rgb : Int32) : Int32
        return rgb if @colors.true_color?
        cache = (@quant_cache ||= {} of Int32 => Int32)
        cache[rgb]? || (cache[rgb] = nearest_palette_rgb((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff))
      end

      @quant_cache : Hash(Int32, Int32)?

      # The xterm palette as packed `0xRRGGBB`, precomputed once from
      # `TermColors::HI2RGB` so `Media.nearest_index` is a flat `Array(Int32)`
      # scan: first 8 entries are `C8`, first 16 are `C16`, all 256 are `C256`.
      C256_PALETTE = TermColors::HI2RGB.map { |(pr, pg, pb)| (pr << 16) | (pg << 8) | pb }
      C16_PALETTE  = C256_PALETTE[0, 16]
      C8_PALETTE   = C256_PALETTE[0, 8]

      # Packed RGB of the nearest xterm-256 (or 16/8) palette color to *r*,*g*,*b*.
      private def nearest_palette_rgb(r : Int32, g : Int32, b : Int32) : Int32
        pal = @colors.c8? ? C8_PALETTE : (@colors.c16? ? C16_PALETTE : C256_PALETTE)
        pal[Media.nearest_index(pal, r, g, b)]
      end

      # Fetches *url* using `curl` (then `wget`), returning the raw bytes.
      def self.fetch(url : String) : Bytes
        [{"curl", ["-s", "-A", "", url]}, {"wget", ["-U", "", "-O", "-", url]}].each do |cmd, args|
          begin
            io = IO::Memory.new
            status = Process.run(cmd, args, output: io, error: Process::Redirect::Close)
            return io.to_slice if status.success?
          rescue
            # Try the next downloader.
          end
        end
        raise "curl or wget failed."
      end
    end

    # ---- single-colormode ASCII backends -------------------------------
    # The no-Unicode capability tier: each concrete widget pins one `Ansi`
    # `ColorMode`, giving a one-variant backend that can be exemplified and
    # documented on its own. Grouped under `Ascii::` (parallel to `Unicode::`);
    # `Ansi` itself stays mode-selectable via `colors:` for programmatic use.
    # `Solid` variants paint space + bg = pixel colour; `Art` variants render
    # the libcaca luminance ramp (`ascii: true`). Palette depth is the second
    # axis (`TrueColor`/`C256`/`C16`/`C8`).
    module Media::Ascii
      # Solid color blocks (space + bg = pixel color), by palette depth.
      #
      # <!-- widget-examples:capture v1 -->
      # ![TrueColor screenshot](../../../../tests/widget/media/ansi/truecolor/truecolor.5s.apng)
      # <!-- /widget-examples:capture -->
      #
      # <!-- widget-examples:capture v1 -->
      # ![TrueColor screenshot](../../../../../tests/widget/media/ansi/art/truecolor/truecolor.5s.apng)
      # <!-- /widget-examples:capture -->
      class TrueColor < Ansi
        def initialize(**box)
          super **box.merge(colors: Ansi::ColorMode::TrueColor)
        end
      end

      # <!-- widget-examples:capture v1 -->
      # ![C256 screenshot](../../../../tests/widget/media/ansi/c256/c256.5s.apng)
      # <!-- /widget-examples:capture -->
      # <!-- widget-examples:capture v1 -->
      # ![C256 screenshot](../../../../../tests/widget/media/ansi/art/c256/c256.5s.apng)
      # <!-- /widget-examples:capture -->
      class C256 < Ansi
        def initialize(**box)
          super **box.merge(colors: Ansi::ColorMode::C256)
        end
      end

      # <!-- widget-examples:capture v1 -->
      # ![C16 screenshot](../../../../tests/widget/media/ansi/c16/c16.5s.apng)
      # <!-- /widget-examples:capture -->
      # <!-- widget-examples:capture v1 -->
      # ![C16 screenshot](../../../../../tests/widget/media/ansi/art/c16/c16.5s.apng)
      # <!-- /widget-examples:capture -->
      class C16 < Ansi
        def initialize(**box)
          super **box.merge(colors: Ansi::ColorMode::C16)
        end
      end

      # <!-- widget-examples:capture v1 -->
      # ![C8 screenshot](../../../../tests/widget/media/ansi/c8/c8.5s.apng)
      # <!-- /widget-examples:capture -->
      # <!-- widget-examples:capture v1 -->
      # ![C8 screenshot](../../../../../tests/widget/media/ansi/art/c8/c8.5s.apng)
      # <!-- /widget-examples:capture -->
      class C8 < Ansi
        def initialize(**box)
          super **box.merge(colors: Ansi::ColorMode::C8)
        end
      end

      # Luminance-ramp ASCII art (libcaca DCHARS), by palette depth.
      module Art
        # <!-- widget-examples:capture v1 -->
        # ![TrueColor screenshot](../../../../tests/widget/media/ansi/truecolor/truecolor.5s.apng)
        # <!-- /widget-examples:capture -->
        # <!-- widget-examples:capture v1 -->
        # ![TrueColor screenshot](../../../../../tests/widget/media/ansi/art/truecolor/truecolor.5s.apng)
        # <!-- /widget-examples:capture -->
        class TrueColor < Ansi
          def initialize(**box)
            super **box.merge(colors: Ansi::ColorMode::TrueColor, ascii: true)
          end
        end

        # <!-- widget-examples:capture v1 -->
        # ![C256 screenshot](../../../../tests/widget/media/ansi/c256/c256.5s.apng)
        # <!-- /widget-examples:capture -->
        # <!-- widget-examples:capture v1 -->
        # ![C256 screenshot](../../../../../tests/widget/media/ansi/art/c256/c256.5s.apng)
        # <!-- /widget-examples:capture -->
        class C256 < Ansi
          def initialize(**box)
            super **box.merge(colors: Ansi::ColorMode::C256, ascii: true)
          end
        end

        # <!-- widget-examples:capture v1 -->
        # ![C16 screenshot](../../../../tests/widget/media/ansi/c16/c16.5s.apng)
        # <!-- /widget-examples:capture -->
        # <!-- widget-examples:capture v1 -->
        # ![C16 screenshot](../../../../../tests/widget/media/ansi/art/c16/c16.5s.apng)
        # <!-- /widget-examples:capture -->
        class C16 < Ansi
          def initialize(**box)
            super **box.merge(colors: Ansi::ColorMode::C16, ascii: true)
          end
        end

        # <!-- widget-examples:capture v1 -->
        # ![C8 screenshot](../../../../tests/widget/media/ansi/c8/c8.5s.apng)
        # <!-- /widget-examples:capture -->
        # <!-- widget-examples:capture v1 -->
        # ![C8 screenshot](../../../../../tests/widget/media/ansi/art/c8/c8.5s.apng)
        # <!-- /widget-examples:capture -->
        class C8 < Ansi
          def initialize(**box)
            super **box.merge(colors: Ansi::ColorMode::C8, ascii: true)
          end
        end
      end
    end
  end
end
