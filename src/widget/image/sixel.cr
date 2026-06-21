require "./graphics"

module Crysterm
  class Widget
    # Renders an image as **sixel** graphics: an in-band DCS escape sequence that
    # a sixel-capable terminal (xterm -ti vt340, foot, wezterm, mlterm, …) draws
    # as true raster pixels at the cursor position. Unlike `Image::Ansi`/`Image::Glyph`
    # the pixels are owned by the terminal, not Crysterm's cell grid — so this
    # inherits `Image::Graphics`'s screen-owns-pixels erase/redraw lifecycle.
    #
    # The image is quantized to a fixed 6×7×6 (=252) level RGB palette, with
    # 4×4 ordered (Bayer) dithering on by default to smooth gradients, then
    # emitted as run-length-encoded sixel bands.
    #
    # ```
    # img = Widget::Image::Sixel.new file: "pic.png", width: 40, height: 12, parent: screen
    # ```
    class Image::Sixel < Image::Graphics
      # Palette levels per channel (product must stay ≤ 256 color registers).
      LR = 6
      LG = 7
      LB = 6

      # Apply ordered dithering when quantizing to the palette.
      property? dither : Bool = true

      def initialize(*args, dither : Bool = true, **opts)
        @dither = dither
        super *args, **opts
      end

      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        {cols * cell_pixel_width, rows * cell_pixel_height}
      end

      # Sixel draws at the text cursor (positioned by the base class), so the
      # *ox*/*oy* pixel origin is unused here.
      def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32) : String
        idx = quantize bmp, pw, ph

        io = String::Builder.new
        io << "\eP0;1;0q"                 # DCS sixel; P2=1 → leave 0-bits transparent
        io << "\"1;1;" << pw << ';' << ph # raster attrs: 1:1 aspect, pw×ph

        PALETTE.each_with_index do |rgb, i|
          io << '#' << i << ";2;" << (((rgb >> 16) & 0xff) * 100 // 255) << ';' << (((rgb >> 8) & 0xff) * 100 // 255) << ';' << ((rgb & 0xff) * 100 // 255)
        end

        bands = (ph + 5) // 6
        bands.times do |band|
          y0 = band * 6
          # color index -> one 6-bit sixel value per column
          cols = Hash(Int32, Array(UInt8)).new
          pw.times do |x|
            6.times do |dy|
              y = y0 + dy
              break if y >= ph
              ci = idx[y][x]
              next if ci < 0 # transparent (e.g. Contain letterbox margin)
              arr = cols[ci] ||= Array(UInt8).new(pw, 0u8)
              arr[x] = (arr[x] | (1u8 << dy))
            end
          end

          first = true
          cols.each do |ci, vals|
            io << '$' unless first # graphics CR: overlay next color in same band
            first = false
            io << '#' << ci
            emit_rle io, vals, pw
          end
          io << '-' # graphics NL: advance to next band
        end

        io << "\e\\" # ST
        io.to_s
      end

      # Run-length-encode a band's sixel values (`!count char`, or literals for
      # short runs).
      private def emit_rle(io : String::Builder, vals : Array(UInt8), w : Int32)
        x = 0
        while x < w
          v = vals[x]
          ch = (0x3f + v).chr
          rl = 1
          while x + rl < w && vals[x + rl] == v
            rl += 1
          end
          if rl >= 4
            io << '!' << rl << ch
          else
            rl.times { io << ch }
          end
          x += rl
        end
      end

      # Maps each pixel to a palette index, optionally Bayer-dithered.
      private def quantize(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32) : Array(Array(Int32))
        out = Array(Array(Int32)).new(ph)
        ph.times do |y|
          rin = bmp[y]
          row = Array(Int32).new(pw, 0)
          pw.times do |x|
            px = rin[x]?
            next unless px
            if px.a == 0
              row[x] = -1 # transparent
              next
            end
            t = dither? ? (BAYER[y & 3][x & 3] + 0.5) / 16.0 - 0.5 : 0.0
            rl = qlevel px.r, LR, t
            gl = qlevel px.g, LG, t
            bl = qlevel px.b, LB, t
            row[x] = (rl * LG + gl) * LB + bl
          end
          out << row
        end
        out
      end

      # Quantizes one channel value (0..255) to a level (0..l-1), nudged by the
      # dither threshold *t* in [-0.5, 0.5).
      private def qlevel(v : Int32, l : Int32, t : Float64) : Int32
        step = 255.0 / (l - 1)
        q = ((v + t * step) / step).round.to_i
        q < 0 ? 0 : (q > l - 1 ? l - 1 : q)
      end

      # 6×7×6 RGB palette, index = (r*LG + g)*LB + b (must match `#quantize`).
      PALETTE = begin
        arr = [] of Int32
        LR.times do |r|
          LG.times do |g|
            LB.times do |b|
              rr = r * 255 // (LR - 1)
              gg = g * 255 // (LG - 1)
              bb = b * 255 // (LB - 1)
              arr << ((rr << 16) | (gg << 8) | bb)
            end
          end
        end
        arr
      end

      # 4×4 Bayer ordered-dither matrix (values 0..15).
      BAYER = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
      ]
    end
  end
end
