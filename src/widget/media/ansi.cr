require "../../widget_media_cells"
require "term_colors"

module Crysterm
  class Widget
    # Renders a PNG / APNG / GIF image as colored terminal cells, ported from
    # Blessed's `ansiimage` element.
    #
    # Unlike `Widget::Media::Overlay` (which paints a true-color image *over* the
    # terminal via the external `w3mimgdisplay` helper), `Media::Ansi` decodes the
    # image itself — using the pure-Crystal `PNGGIF::PNG` reader — and draws it
    # into the normal cell grid. Each pixel of the downscaled image becomes one
    # cell whose background is that pixel's color, so the result is portable to
    # any TrueColor terminal with no external dependencies.
    #
    # Because Crysterm renders in TrueColor, pixel RGB values are used directly;
    # there is no 256-color palette-matching step as in Blessed.
    #
    # ```
    # img = Widget::Media::Ansi.new file: "picture.png", width: 30, parent: screen
    # ```
    #
    # Animated images (APNG, animated GIF) play automatically unless `animate:
    # false` is passed; `#play`, `#pause` and `#stop` control playback (the
    # animation framework is shared, in `Media::Base`).
    class Media::Ansi < Media::Cells
      # Color depth the image is rendered in. Crysterm is natively TrueColor and
      # only reduces colors at output time when the terminal can't do 24-bit; the
      # non-`TrueColor` modes here additionally *quantize the pixels themselves*
      # to the xterm-256 or 16-color palette, so the classic low-color look is
      # produced (and preserved) regardless of the terminal's own capability —
      # the portability story Blessed's `ansiimage` had via palette-matching.
      enum ColorMode
        TrueColor # 24-bit RGB used directly (default)
        C256      # quantized to the xterm 256-color palette
        C16       # quantized to the 16-color ANSI palette
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

      # Terminal cell height-to-width ratio, used to keep the image's aspect
      # ratio correct on non-square cells (~2.0 for typical monospace fonts). A
      # value of `1.0` assumes square cells. Changing it after construction takes
      # effect on the next `#set_image`.
      property cell_aspect : Float64

      def initialize(
        @file = nil,
        @scale : Float64 = 1.0,
        animate : Bool | Timer = true,
        @ascii : Bool = false,
        @speed : Float64 = 1.0,
        @cell_aspect : Float64 = 2.0,
        @colors : ColorMode = ColorMode::TrueColor,
        @dither : Media::Dither = Media::Dither::Auto,
        @fit : Media::Fit = Media::Fit::Stretch,
        **box,
      )
        # Blessed sets `options.shrink = true`; the Crysterm equivalent is
        # `resizable`, so the widget sizes itself to the image when no explicit
        # width/height is given.
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
        cw = @width.as?(Int32)
        ch = @height.as?(Int32)
        if cw.nil? || ch.nil?
          native = png.create_cellmap(png.bmp, scale: @scale, cell_aspect: @cell_aspect)
          self.width = (native[0]?.try(&.size) || 0) if cw.nil?
          self.height = native.size if ch.nil?
        end
      end

      # One cell per pixel: sample at the content box size, with cell-aspect
      # correction so the image isn't vertically squashed on tall cells.
      protected def compose(img : PNGGIF::PNG, cols : Int32, rows : Int32, frame : PNGGIF::Bitmap?) : PNGGIF::Bitmap?
        if frame
          Media::Fitting.compose(img, frame, cols, rows, @fit, @cell_aspect)
        else
          Media::Fitting.compose(img, cols, rows, @fit, @cell_aspect)
        end
      end

      protected def draw_sample(bmp : PNGGIF::Bitmap, xi : Int32, xl : Int32, yi : Int32, yl : Int32)
        lines = screen.lines
        # In a reduced-color mode, dither the whole sample to the palette up front
        # (error diffusion needs the neighbours, so it can't be done per cell).
        # Memoized per sample bitmap; unused (and never computed) in TrueColor.
        plane = @colors.true_color? ? nil : cached_dither_plane(bmp)
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

      # Writes one image pixel into a screen *cell* (its background *rgb* already
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

        if a < 1.0
          # Composite the image pixel over whatever is currently in the cell.
          cell.attr = Colors.blend(attr, cell.attr, a)
          cell.char = ch unless ch == ' '
        else
          cell.attr = attr
          cell.char = ch
        end
      end

      # Luminance glyphs taken from libcaca (via tng.js).
      DCHARS = "????8@8@#8@8##8#MKXWwz$&%x><\\/xo;+=|^-:i'.`,  `.        "

      # Picks an ASCII glyph + foreground color for *px* (used when `ascii`).
      private def ascii_glyph(px : PNGGIF::Pixel, a : Float64) : Tuple(Char, Int32)
        l = (0.2126 * px.r * a + 0.7152 * px.g * a + 0.0722 * px.b * a) / 255.0
        ch = DCHARS[(l * (DCHARS.size - 1)).to_i]
        # Foreground at half intensity, like tng's `fga = 0.5`.
        fg = ((px.r * a * 0.5).to_i << 16) | ((px.g * a * 0.5).to_i << 8) | (px.b * a * 0.5).to_i
        {ch, fg}
      end

      # Dithered plane for the *current* `@sample`, and the bitmap it was built
      # for. The full Floyd–Steinberg/ordered pass is the per-render hot spot, so
      # it's cached and only rerun when the sample bitmap actually changes. Keying
      # on the bitmap's identity ties the plane's lifetime to `@sample` exactly:
      # every resample (resize, reload, `bitmap=`, `reset_sample_cache`) and every
      # animation frame yields a fresh bitmap object, which forces a recompute,
      # while a repeated render of the same still reuses it.
      @dither_plane : Array(Array(Int32))?
      @dither_plane_for : PNGGIF::Bitmap?

      private def cached_dither_plane(bmp : PNGGIF::Bitmap) : Array(Array(Int32))
        cached = @dither_plane
        return cached if cached && @dither_plane_for.try(&.same?(bmp))
        plane = dither_plane(bmp)
        @dither_plane = plane
        @dither_plane_for = bmp
        plane
      end

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
      # `TermColors::HI2RGB` so the nearest-color search (`Media.nearest_index`)
      # is a flat `Array(Int32)` scan: the first 16 entries are the ANSI palette
      # (`C16`), all 256 the xterm cube (`C256`).
      C256_PALETTE = TermColors::HI2RGB.map { |(pr, pg, pb)| (pr << 16) | (pg << 8) | pb }
      C16_PALETTE  = C256_PALETTE[0, 16]

      # Packed RGB of the nearest xterm-256 (or 16) palette color to *r*,*g*,*b*.
      private def nearest_palette_rgb(r : Int32, g : Int32, b : Int32) : Int32
        pal = @colors.c16? ? C16_PALETTE : C256_PALETTE
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
  end
end
