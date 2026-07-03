require "../../widget_media_graphics"

module Crysterm
  class Widget
    # Renders an image as **ReGIS** graphics: an in-band DCS sequence of vector
    # commands that a ReGIS-capable terminal (xterm built with
    # `--enable-regis-graphics`, or a real VT240/VT330/VT340) draws into the VT
    # window. Like sixel the pixels are owned by the terminal, so this inherits
    # `Media::Graphics`'s window-owns-pixels erase/redraw lifecycle.
    #
    # ReGIS is a *vector* format with no native raster blit, so a photo is
    # quantized to ReGIS's small set of built-in named colors and emitted as
    # run-length horizontal vectors per scan line — a posterized, period-
    # accurate rendering rather than a photographic one. ReGIS also addresses
    # *absolute window pixels* (not the text cursor), so the widget's pixel
    # origin is honored.
    #
    # ```
    # img = Widget::Media::Regis.new file: "pic.png", width: 48, height: 14, parent: window
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Regis screenshot](../../../tests/widget/media/regis/regis.5s.apng)
    # <!-- /widget-examples:capture -->
    class Media::Regis < Media::Graphics
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

      # How colors are dithered down to ReGIS' 8-color palette. `Dither::None`
      # by default (unlike the raster backends): dithering looks noisy and
      # explodes the vector count, since per-pixel color changes break up the
      # run-length horizontal spans. `Ordered`/`Diffusion`/`Auto` are accepted
      # for parity but rarely worth it.
      property dither : Media::Dither = Media::Dither::None

      # ReGIS addresses a *fixed logical window* (not raw window pixels): xterm
      # maps `[0,0]..[regis_width-1, regis_height-1]` onto the whole text area.
      # These default to xterm's typical ReGIS window; set the matching
      # `XTerm*regisScreenSize` resource (e.g. `1100x400`) so the logical space
      # fills the window. The widget's cell box is mapped into this space.
      property regis_width : Int32 = 800
      property regis_height : Int32 = 480

      def initialize(*args, dither : Media::Dither | Bool = Media::Dither::None,
                     regis_width : Int32 = 0, regis_height : Int32 = 0, **opts)
        # Accept a legacy Bool: true ⇒ ordered (its prior meaning), false ⇒ none.
        @dither = Media::Dither.from_arg(dither, Media::Dither::Ordered)
        @regis_width = regis_width
        @regis_height = regis_height
        super *args, **opts
        # 0 ⇒ auto: derive the logical window from the terminal's real pixel
        # size (per-cell pixels already detected via TIOCGWINSZ). Pair with
        # xterm's `regisScreenSize: auto` so the image fills the window instead
        # of leaving a black margin.
        if @regis_width <= 0
          @regis_width = cell_pixel_width * (window?.try(&.awidth) || 80)
        end
        if @regis_height <= 0
          @regis_height = cell_pixel_height * (window?.try(&.aheight) || 24)
        end
      end

      # ReGIS draws thousands of vectors per frame, too slow for smooth
      # animated playback — an animated source just shows its first frame.
      protected def needs_frame_loop? : Bool
        false
      end

      # Map the cell box into ReGIS' logical window (a fraction of the whole
      # terminal). One bitmap pixel per logical unit keeps spans aligned.
      def target_pixels(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        sc = window.awidth
        sr = window.aheight
        pw = sc > 0 ? (cols * @regis_width / sc).to_i : cols
        ph = sr > 0 ? (rows * @regis_height / sr).to_i : rows
        {pw < 1 ? 1 : pw, ph < 1 ? 1 : ph}
      end

      # Logical origin of the content box within the ReGIS window.
      protected def origin_pixels(xi : Int32, yi : Int32) : Tuple(Int32, Int32)
        sc = window.awidth
        sr = window.aheight
        ox = sc > 0 ? (xi * @regis_width / sc).to_i : xi
        oy = sr > 0 ? (yi * @regis_height / sr).to_i : yi
        {ox, oy}
      end

      def encode(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32, ox : Int32, oy : Int32,
                 cols : Int32, rows : Int32) : String
        idx = quantize bmp, pw, ph

        io = String::Builder.new
        io << "\ePp" # enter ReGIS

        last = -1
        ph.times do |y|
          ry = oy + y
          Media.each_run(idx[y], pw) do |ci, x, rl|
            next if ci < 0 # transparent (e.g. Contain letterbox margin): draw nothing

            if ci != last
              io << "W(I(" << LETTERS[ci] << "))"
              last = ci
            end
            x0 = ox + x
            x1 = ox + x + rl - 1
            # Position (beam off) then draw a horizontal vector across the run.
            io << "P[" << x0 << ',' << ry << "]V[" << x1 << ',' << ry << ']'
          end
        end

        io << "\e\\" # exit ReGIS
        io.to_s
      end

      # ReGIS never drives a frame loop (`needs_frame_loop?` is false), so the
      # dither is always resolved as for a still image.
      private def quantize(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32) : Array(Array(Int32))
        Media.dither_rgb(bmp, pw, ph, @dither, false, -1) do |r, g, b, t|
          if t != 0.0
            n = t * 110.0
            r = Media.clamp8 (r + n).round.to_i
            g = Media.clamp8 (g + n).round.to_i
            b = Media.clamp8 (b + n).round.to_i
          end
          ci = Media.nearest_index PALETTE, r, g, b
          rgb = PALETTE[ci]
          {ci, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff}
        end
      end
    end
  end
end
