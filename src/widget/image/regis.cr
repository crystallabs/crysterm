require "./graphics"

module Crysterm
  class Widget
    # Renders an image as **ReGIS** graphics: an in-band DCS sequence of vector
    # commands that a ReGIS-capable terminal (xterm built with
    # `--enable-regis-graphics`, or a real VT240/VT330/VT340) draws into the VT
    # window. Like sixel the pixels are owned by the terminal, so this inherits
    # `Image::Graphics`'s screen-owns-pixels erase/redraw lifecycle.
    #
    # ReGIS is a *vector* format with no native raster blit, so a photo is drawn
    # the only faithful way: quantized to ReGIS's small set of built-in named
    # colors and emitted as one run-length set of horizontal vectors per scan
    # line. The result is a posterized, period-accurate ReGIS rendering rather
    # than a photographic one. ReGIS also addresses *absolute window pixels*
    # (not the text cursor), so the widget's pixel origin is honored.
    #
    # ```
    # img = Widget::Image::Regis.new file: "pic.png", width: 48, height: 14, parent: screen
    # ```
    class Image::Regis < Image::Graphics
      # ReGIS built-in named colors and their approximate RGB, used for
      # nearest-color quantization. Letter order defines the palette index.
      LETTERS = "DRGBCMYW"
      PALETTE = [
        0x000000, # D dark/black
        0xFF0000, # R red
        0x00FF00, # G green
        0x0000FF, # B blue
        0x00FFFF, # C cyan
        0xFF00FF, # M magenta
        0xFFFF00, # Y yellow
        0xFFFFFF, # W white
      ]

      # Apply 4×4 ordered (Bayer) dithering. Off by default: ReGIS has only 8
      # colors and no raster blit, so dithering both looks noisy and explodes
      # the vector count (it breaks up the run-length horizontal spans).
      property? dither : Bool = false

      # ReGIS addresses a *fixed logical screen* (not raw window pixels): xterm
      # maps `[0,0]..[regis_width-1, regis_height-1]` onto the whole text area.
      # These default to xterm's typical ReGIS screen; set the matching
      # `XTerm*regisScreenSize` resource (e.g. `1100x400`) so the logical space
      # fills the window. The widget's cell box is mapped into this space.
      property regis_width : Int32 = 800
      property regis_height : Int32 = 480

      def initialize(*args, dither : Bool = false,
                     regis_width : Int32 = 800, regis_height : Int32 = 480, **opts)
        @dither = dither
        @regis_width = regis_width
        @regis_height = regis_height
        super *args, **opts
      end

      # ReGIS draws an animated image's frames one vector at a time — thousands
      # of vectors per frame — which the terminal renders far too slowly for
      # smooth playback, so we don't drive a frame loop: an animated source just
      # shows its first frame.
      protected def needs_frame_loop? : Bool
        false
      end

      # Map the cell box into ReGIS' logical screen (a fraction of the whole
      # terminal). One bitmap pixel per logical unit keeps spans aligned.
      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        sc = screen.awidth
        sr = screen.aheight
        pw = sc > 0 ? (cols * @regis_width / sc).to_i : cols
        ph = sr > 0 ? (rows * @regis_height / sr).to_i : rows
        {pw < 1 ? 1 : pw, ph < 1 ? 1 : ph}
      end

      # Logical origin of the content box within the ReGIS screen.
      protected def origin_pixels(xi : Int32, yi : Int32) : Tuple(Int32, Int32)
        sc = screen.awidth
        sr = screen.aheight
        ox = sc > 0 ? (xi * @regis_width / sc).to_i : xi
        oy = sr > 0 ? (yi * @regis_height / sr).to_i : yi
        {ox, oy}
      end

      def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32) : String
        idx = quantize bmp, pw, ph

        io = String::Builder.new
        io << "\ePp" # enter ReGIS

        last = -1
        ph.times do |y|
          ry = oy + y
          x = 0
          while x < pw
            ci = idx[y][x]
            rl = 1
            while x + rl < pw && idx[y][x + rl] == ci
              rl += 1
            end

            if ci < 0 # transparent (e.g. Contain letterbox margin): draw nothing
              x += rl
              next
            end

            if ci != last
              io << "W(I(" << LETTERS[ci] << "))"
              last = ci
            end
            x0 = ox + x
            x1 = ox + x + rl - 1
            # Position (beam off) then draw a horizontal vector across the run.
            io << "P[" << x0 << ',' << ry << "]V[" << x1 << ',' << ry << ']'
            x += rl
          end
        end

        io << "\e\\" # exit ReGIS
        io.to_s
      end

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
            r = px.r; g = px.g; b = px.b
            if dither?
              t = ((BAYER[y & 3][x & 3] + 0.5) / 16.0 - 0.5) * 110.0
              r = clamp8 (r + t).to_i
              g = clamp8 (g + t).to_i
              b = clamp8 (b + t).to_i
            end
            row[x] = nearest r, g, b
          end
          out << row
        end
        out
      end

      # Index of the nearest palette color to (r,g,b) by squared distance.
      private def nearest(r : Int32, g : Int32, b : Int32) : Int32
        best = 0
        bestd = Int32::MAX
        PALETTE.each_with_index do |rgb, i|
          dr = r - ((rgb >> 16) & 0xff)
          dg = g - ((rgb >> 8) & 0xff)
          db = b - (rgb & 0xff)
          d = dr*dr + dg*dg + db*db
          if d < bestd
            bestd = d
            best = i
          end
        end
        best
      end

      private def clamp8(v : Int32) : Int32
        v < 0 ? 0 : (v > 255 ? 255 : v)
      end

      BAYER = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
      ]
    end
  end
end
