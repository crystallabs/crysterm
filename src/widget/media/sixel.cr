require "../../widget_media_graphics"

module Crysterm
  class Widget
    # Renders an image as **sixel** graphics: an in-band DCS escape sequence that
    # a sixel-capable terminal (xterm -ti vt340, foot, wezterm, mlterm, …) draws
    # as true raster pixels at the cursor position. The pixels are owned by the
    # terminal, not Crysterm's cell grid, so this inherits `Media::Graphics`'s
    # erase/redraw lifecycle.
    #
    # The image is quantized to a fixed 6×7×6 (=252) level RGB palette and
    # dithered to smooth gradients, then emitted as run-length-encoded sixel
    # bands.
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

      # How the image's colors are dithered down to the fixed palette. Under
      # `Dither::Auto`: Floyd–Steinberg error diffusion for a still (best
      # quality), ordered (Bayer) for an animation (frame-stable, so the gradient
      # noise doesn't shimmer between frames).
      property dither : Media::Dither = Media::Dither::Auto

      def initialize(*args, dither : Media::Dither = Media::Dither::Auto, **opts)
        @dither = dither
        super *args, **opts
      end

      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        {cols * cell_pixel_width, rows * cell_pixel_height}
      end

      # Per-frame scratch reused across renders when `media.reuse_buffers` is on;
      # a per-frame-re-encoding sixel would otherwise re-allocate the whole set
      # every frame. Safe because encoding runs only on the single render fiber.
      @quant_scratch : Array(Array(Int32))? = nil
      @row_scratch : Array(Array(UInt8))? = nil
      @seen_scratch : Array(Int32)? = nil
      @band_of_scratch : Array(Int32)? = nil
      # Previous frame's encoded byte size, used (with reuse on) to pre-size the
      # output builder. RLE output size is content-dependent so it can't be
      # computed up front, but consecutive frames are very close in size — a
      # slight over/under-estimate at worst trims or triggers one growth.
      @last_payload_bytes = 0

      # Sixel draws at the text cursor at exact pixel resolution, so *ox*/*oy*
      # and the *cols*/*rows* cell box are unused.
      def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                 cols : Int32, rows : Int32) : String
        reuse = Config.media_reuse_buffers
        idx = quantize bmp, pw, ph, reuse

        io = (reuse && @last_payload_bytes > 0) ? String::Builder.new(@last_payload_bytes + 64) : String::Builder.new
        io << "\eP0;1;0q"                 # DCS sixel; P2=1 → leave 0-bits transparent
        io << "\"1;1;" << pw << ';' << ph # raster attrs: 1:1 aspect, pw×ph

        PALETTE.each_with_index do |rgb, i|
          io << '#' << i << ";2;" << (((rgb >> 16) & 0xff) * 100 // 255) << ';' << (((rgb >> 8) & 0xff) * 100 // 255) << ';' << ((rgb & 0xff) * 100 // 255)
        end

        # Scratch shared across all bands: one `pw`-wide sixel row per palette
        # color, `seen` = colors first touched this band (in first-touch order,
        # so emission is deterministic), and `band_of[ci]` = the band that last
        # touched color `ci` (an allocation-free "seen this band?" test). These
        # persist across frames under reuse, so each band must leave its
        # `scratch` rows re-zeroed below.
        if reuse && (rs = @row_scratch) && (ss = @seen_scratch) && (bs = @band_of_scratch) &&
           rs.size == PALETTE.size && (rs[0]?.try(&.size) || 0) == pw
          scratch = rs
          seen = ss
          band_of = bs
          band_of.fill(-1)
        else
          scratch = Array(Array(UInt8)).new(PALETTE.size) { Array(UInt8).new(pw, 0u8) }
          seen = [] of Int32
          band_of = Array(Int32).new(PALETTE.size, -1)
          if reuse
            @row_scratch = scratch
            @seen_scratch = seen
            @band_of_scratch = band_of
          end
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
        result = io.to_s
        @last_payload_bytes = result.bytesize if reuse
        result
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

      # Maps each pixel to a palette index, with `-1` for fully transparent
      # pixels. With *reuse* on, the large `ph`×`pw` index grid is filled into a
      # persistent scratch instead of freshly allocated every frame.
      private def quantize(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, reuse : Bool = false) : Array(Array(Int32))
        into = nil
        if reuse
          qs = @quant_scratch
          qs = @quant_scratch = Array(Array(Int32)).new(ph) { Array(Int32).new(pw, -1) } \
            if qs.nil? || qs.size != ph || (qs[0]?.try(&.size) || 0) != pw
          into = qs
        end
        Media.dither_rgb(bmp, pw, ph, @dither, frames_ready?, -1, into) do |r, g, b, t|
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
