require "./cells"
require "term_colors"

module Crysterm
  class Widget
    # Renders a PNG / APNG / GIF image as colored terminal cells, ported from
    # Blessed's `ansiimage` element.
    #
    # Unlike `Widget::Image::Overlay` (which paints a true-color image *over* the
    # terminal via the external `w3mimgdisplay` helper), `Image::Ansi` decodes the
    # image itself — using the pure-Crystal `PNGGIF::PNG` reader — and draws it
    # into the normal cell grid. Each pixel of the downscaled image becomes one
    # cell whose background is that pixel's color, so the result is portable to
    # any TrueColor terminal with no external dependencies.
    #
    # Because Crysterm renders in TrueColor, pixel RGB values are used directly;
    # there is no 256-color palette-matching step as in Blessed.
    #
    # ```
    # img = Widget::Image::Ansi.new file: "picture.png", width: 30, parent: screen
    # ```
    #
    # Animated images (APNG, animated GIF) play automatically unless `animate:
    # false` is passed; `#play`, `#pause` and `#stop` control playback (the
    # animation framework is shared, in `Image::Base`).
    class Image::Ansi < Image::Cells
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
        @animate : Bool = true,
        @ascii : Bool = false,
        @speed : Float64 = 1.0,
        @cell_aspect : Float64 = 2.0,
        @colors : ColorMode = ColorMode::TrueColor,
        @fit : Image::Fit = Image::Fit::Stretch,
        **box,
      )
        # Blessed sets `options.shrink = true`; the Crysterm equivalent is
        # `resizable`, so the widget sizes itself to the image when no explicit
        # width/height is given.
        super(**box.merge(resizable: true))

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
          Image::Fitting.compose(img, frame, cols, rows, @fit, @cell_aspect)
        else
          Image::Fitting.compose(img, cols, rows, @fit, @cell_aspect)
        end
      end

      protected def draw_sample(bmp : PNGGIF::Bitmap, xi : Int32, xl : Int32, yi : Int32, yl : Int32)
        lines = screen.lines
        (yi...yl).each do |y|
          cmrow = bmp[y - yi]?
          next unless cmrow
          row = lines[y]?
          next unless row
          (xi...xl).each do |x|
            px = cmrow[x - xi]?
            next unless px
            cell = row[x]?
            next unless cell
            a = px.a / 255.0
            next if a == 0.0 # fully transparent: leave the cell as-is
            paint_cell cell, px, a
          end
          row.dirty = true
        end
      end

      # Writes one image pixel into a screen *cell*, blending against the cell's
      # current contents when the pixel is translucent.
      private def paint_cell(cell, px : PNGGIF::Pixel, a : Float64)
        rgb = quantize((px.r << 16) | (px.g << 8) | px.b)

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

      # Quantizes *rgb* to the nearest color of the active palette (`C256`/`C16`),
      # or returns it unchanged in `TrueColor` mode. Results are memoized since an
      # image has far fewer distinct pixel colors than cells.
      private def quantize(rgb : Int32) : Int32
        return rgb if @colors.true_color?
        cache = (@quant_cache ||= {} of Int32 => Int32)
        if q = cache[rgb]?
          return q
        end
        r = (rgb >> 16) & 0xff
        g = (rgb >> 8) & 0xff
        b = rgb & 0xff
        n = @colors.c16? ? 16 : 256
        best = 0
        bestd = Int32::MAX
        i = 0
        while i < n
          pr, pg, pb = TermColors::HI2RGB[i]
          dr = r - pr; dg = g - pg; db = b - pb
          d = dr*dr + dg*dg + db*db
          if d < bestd
            bestd = d
            best = i
          end
          i += 1
        end
        pr, pg, pb = TermColors::HI2RGB[best]
        q = (pr << 16) | (pg << 8) | pb
        cache[rgb] = q
        q
      end

      @quant_cache : Hash(Int32, Int32)?

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
