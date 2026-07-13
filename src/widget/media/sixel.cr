require "../../widget_media_graphics"

module Crysterm
  class Widget
    # Renders an image as **sixel** graphics: an in-band DCS escape sequence that
    # a sixel-capable terminal (xterm -ti vt340, foot, wezterm, mlterm, …) draws
    # as true raster pixels at the cursor position. Unlike
    # `Media::Ansi`/`Media::Glyph` the pixels are owned by the terminal, not
    # Crysterm's cell grid — so this inherits `Media::Graphics`'s
    # window-owns-pixels erase/redraw lifecycle.
    #
    # The image is quantized to a fixed 6×7×6 (=252) level RGB palette and
    # dithered to smooth gradients (see `dither`; `Dither::Auto` by default),
    # then emitted as run-length-encoded sixel bands.
    #
    # ```
    # img = Widget::Media::Sixel.new file: "pic.png", width: 40, height: 12, parent: window
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Sixel screenshot](../../../tests/widget/media/sixel/sixel.5s.apng)
    # <!-- /widget-examples:capture -->
    class Media::Sixel < Media::Graphics
      # Palette levels per channel (product must stay ≤ 256 color registers).
      LR = 6
      LG = 7
      LB = 6

      # How the image's colors are dithered down to the fixed palette. Defaults
      # to `Dither::Auto`: Floyd–Steinberg error diffusion for a still (best
      # quality), ordered (Bayer) dither for an animation (frame-stable, so the
      # gradient noise doesn't shimmer between frames).
      property dither : Media::Dither = Media::Dither::Auto

      def initialize(*args, dither : Media::Dither | Bool = Media::Dither::Auto, **opts)
        # Accept a legacy Bool: true ⇒ auto, false ⇒ none.
        @dither = Media::Dither.from_arg(dither, Media::Dither::Auto)
        super *args, **opts
      end

      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        {cols * cell_pixel_width, rows * cell_pixel_height}
      end

      # Reused sixel band scratch, hoisted to instance vars and refilled in place
      # each frame rather than reallocated (opt-in via `media.reuse_buffers`,
      # mirroring `Media::Kitty`'s `@rgba_scratch`). A sixel-backed chart/donut
      # re-encodes every changed frame, so the fresh `scratch` (`PALETTE.size`
      # ≈252 `pw`-wide rows), `seen` and `band_of` (≈252 ints each) here were
      # per-frame garbage. Encoding runs only on the single render fiber, so one
      # shared buffer is safe. `@scratch_pw` guards the width: when `pw` changes
      # the rows are rebuilt at the new size. Between frames the rows are left
      # fully zeroed (every band's touched rows are `fill(0u8)`-reset at the end
      # of the band, including the last), and `band_of` is re-seeded to `-1` at
      # the start of every encode, so no stale bit from a previous frame can
      # survive the reuse — output stays byte-identical to a fresh allocation.
      @scratch : Array(Array(UInt8)) = Array(Array(UInt8)).new
      @scratch_pw : Int32 = -1
      @seen_scratch : Array(Int32) = [] of Int32
      @band_of_scratch : Array(Int32) = [] of Int32

      # Sixel draws at the text cursor (positioned by the base class) at exact
      # pixel resolution, so *ox*/*oy* and the *cols*/*rows* cell box are unused.
      def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                 cols : Int32, rows : Int32) : String
        idx = quantize bmp, pw, ph

        io = String::Builder.new
        io << "\eP0;1;0q"                 # DCS sixel; P2=1 → leave 0-bits transparent
        io << "\"1;1;" << pw << ';' << ph # raster attrs: 1:1 aspect, pw×ph

        PALETTE.each_with_index do |rgb, i|
          io << '#' << i << ";2;" << (((rgb >> 16) & 0xff) * 100 // 255) << ';' << (((rgb >> 8) & 0xff) * 100 // 255) << ';' << ((rgb & 0xff) * 100 // 255)
        end

        # Reusable scratch shared across all bands (avoids per-band allocation):
        # one `pw`-wide sixel row per palette color (`PALETTE.size` = 252), the
        # list of colors first touched this band (in first-touch order, so
        # emission order is deterministic), and `band_of[ci]` = the band that
        # last touched color `ci` (the allocation-free "seen this band?" test).
        # With `media.reuse_buffers` these are reused across frames too (see the
        # `@scratch` note above); otherwise they are freshly allocated per call.
        if Config.media_reuse_buffers
          scratch = @scratch
          if @scratch_pw != pw
            scratch.clear
            PALETTE.size.times { scratch << Array(UInt8).new(pw, 0u8) }
            @scratch_pw = pw
          end
          # scratch rows are left all-zero after a completed encode, so no
          # start-of-frame clear is needed here.
          seen = @seen_scratch
          seen.clear
          band_of = @band_of_scratch
          if band_of.size == PALETTE.size
            band_of.fill(-1)
          else
            band_of.clear
            PALETTE.size.times { band_of << -1 }
          end
        else
          scratch = Array(Array(UInt8)).new(PALETTE.size) { Array(UInt8).new(pw, 0u8) }
          seen = [] of Int32
          band_of = Array(Int32).new(PALETTE.size, -1)
        end

        bands = (ph + 5) // 6
        bands.times do |band|
          y0 = band * 6
          seen.clear
          pw.times do |x|
            6.times do |dy|
              y = y0 + dy
              break if y >= ph
              ci = idx[y][x]
              next if ci < 0 # transparent (e.g. Contain letterbox margin)
              if band_of[ci] != band
                band_of[ci] = band
                seen << ci
              end
              arr = scratch[ci]
              arr[x] = (arr[x] | (1u8 << dy))
            end
          end

          first = true
          seen.each do |ci|
            io << '$' unless first # graphics CR: overlay next color in same band
            first = false
            io << '#' << ci
            emit_rle io, scratch[ci], pw
          end
          io << '-' # graphics NL: advance to next band

          # Reset only the rows this band touched, ready for the next band.
          seen.each { |ci| scratch[ci].fill(0u8) }
        end

        io << "\e\\" # ST
        io.to_s
      end

      # Run-length-encode a band's sixel values (`!count char`, or literals for
      # short runs).
      private def emit_rle(io : String::Builder, vals : Array(UInt8), w : Int32)
        Media.each_run(vals, w) do |v, _x, rl|
          ch = (0x3f + v).chr
          if rl >= 4
            io << '!' << rl << ch
          else
            rl.times { io << ch }
          end
        end
      end

      # Maps each pixel to a palette index via the shared dithering loop (`None`/
      # `Ordered`/`Diffusion`), with `-1` for fully transparent pixels.
      private def quantize(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32) : Array(Array(Int32))
        Media.dither_rgb(bmp, pw, ph, @dither, frames_ready?, -1) do |r, g, b, t|
          rl = qlevel r, LR, t
          gl = qlevel g, LG, t
          bl = qlevel b, LB, t
          idx = (rl * LG + gl) * LB + bl
          rgb = PALETTE[idx]
          dr, dg, db = Media.rgb24(rgb)
          {idx, dr, dg, db}
        end
      end

      # Quantizes one channel value (0..255) to a level (0..l-1), nudged by the
      # ordered-dither threshold *t* in [-0.5, 0.5) (0.0 for none/diffusion).
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
              arr << Colors.rgb(rr, gg, bb)
            end
          end
        end
        arr
      end
    end
  end
end
