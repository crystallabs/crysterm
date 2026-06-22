require "../image"
require "../box"

module Crysterm
  class Widget
    # Renders an image in **Tektronix 4014** vector graphics. Emitting `ESC[?38h`
    # switches an xterm built with `--enable-tek4014` into its Tek emulation,
    # which opens a *separate* window (named `tektronix`) and draws on a
    # simulated storage-tube display. This is fundamentally unlike the other
    # image widgets: the Tek display is monochrome (1-bit), vector-only (no
    # raster blit, no partial erase — only a whole-screen PAGE), and lives in its
    # own window, so it does NOT share the cell-grid or screen-overlay erase
    # lifecycles. It's a deliberate takeover of the display.
    #
    # A photo is therefore dithered to 1 bit and drawn as one run of horizontal
    # vectors per "ink" span — a faithfully retro green-on-black rendering.
    #
    # ```
    # tek = Widget::Image::Tek.new file: "pic.png", parent: screen
    # # the Tek window appears on the next screen render
    # ```
    class Image::Tek < Box
      # Tektronix 4014 addressable space (10-bit X, ~0..779 visible Y).
      TEK_W = 1024
      TEK_H =  780
      GS    = '\u{1d}' # enter Tek graph (vector) mode
      US    = '\u{1f}' # return to Tek alpha mode
      ETX   = '\u{03}' # with a leading ESC: leave Tek mode, back to VT100/ANSI

      property file : String?

      # Luminance threshold (0..255) used when `dither?` is off.
      getter level : Float64

      # Ordered-dither to 1 bit (smoother, more photographic) vs. hard threshold
      # (cleaner spans, faster to draw).
      getter? dither : Bool

      # Invert ink/paper (draw the dark areas instead of the bright ones).
      getter? invert : Bool

      # Longest image edge, in Tek units, the rendering is scaled to fit.
      getter fit : Int32

      # The Tek display is a separate window that xterm auto-rescales from the
      # 4014 logical coordinate space, so a window/box resize needs no redraw.
      # Changing the *drawing* parameters does, though — these setters re-fire it.
      def level=(v : Float64)
        return if v == @level
        @level = v
        redraw!
      end

      def dither=(v : Bool)
        return if v == @dither
        @dither = v
        redraw!
      end

      def invert=(v : Bool)
        return if v == @invert
        @invert = v
        redraw!
      end

      def fit=(v : Int32)
        return if v == @fit
        @fit = v
        redraw!
      end

      # Forces the image to be re-emitted to the Tek window on the next render.
      private def redraw!
        @drawn = false
        request_render
      end

      @drawn = false
      @listener_screen : ::Crysterm::Screen?
      @ev_rendered : ::Crysterm::Event::Rendered::Wrapper?

      def initialize(
        @file = nil,
        @level : Float64 = 128.0,
        @dither : Bool = true,
        @invert : Bool = false,
        @fit : Int32 = 680,
        # Accepted-and-ignored so the `Widget::Image` factory can forward one
        # common option bag (incl. overlay-only options) to any backend.
        stretch = false,
        center = false,
        **box,
      )
        super **box

        # Draw into the Tek window once, the first time the screen renders, then
        # unhook — re-flipping to Tek mode every frame would be chaotic.
        s = screen
        @listener_screen = s
        @ev_rendered = s.on(::Crysterm::Event::Rendered) { draw_tek }

        on(::Crysterm::Event::Destroy) { teardown }
      end

      def load(file : String)
        @file = file
        @drawn = false
        request_render
      end

      def set_image(file : String)
        load file
      end

      # Emits the Tek-mode switch and the image as 4014 vectors. Safe to call
      # directly; otherwise it fires once on the first screen render.
      def draw_tek
        return if @drawn
        s = screen? || return
        file = @file || return
        seq = build_sequence(file) || return
        @drawn = true
        s.tput._oprint seq
        s.tput.flush
      end

      private def build_sequence(file : String) : String?
        data : String | Bytes = file
        data = Widget::Image::Ansi.fetch(file) if file =~ /^https?:/

        # Decode once to learn the aspect ratio, then again at the fitted size.
        probe = PNGGIF::PNG.new(data)
        iw = probe.width
        ih = probe.height
        return nil if iw <= 0 || ih <= 0

        if iw >= ih
          pw = @fit
          ph = (@fit * ih / iw).to_i
        else
          ph = @fit
          pw = (@fit * iw / ih).to_i
        end
        pw = 1 if pw < 1
        ph = 1 if ph < 1
        # If the fitted size overruns the addressable Tek space, scale *both*
        # axes down by the same factor so the aspect ratio is preserved (an
        # independent per-axis clamp would squash the image).
        if pw > TEK_W
          ph = (ph * TEK_W / pw).to_i
          pw = TEK_W
        end
        if ph > TEK_H
          pw = (pw * TEK_H / ph).to_i
          ph = TEK_H
        end
        pw = 1 if pw < 1
        ph = 1 if ph < 1

        png = PNGGIF::PNG.new(data, cell_width: pw, cell_height: ph, cell_aspect: 1.0)
        bmp = png.cellmap
        return nil if bmp.empty?
        pw = bmp[0].size
        ph = bmp.size

        bits = to_bits bmp, pw, ph

        io = String::Builder.new
        io << "\e[?38h"  # switch to Tek mode
        io << "\e\u{0c}" # PAGE: clear the storage tube

        ox = (TEK_W - pw) // 2
        ox = 0 if ox < 0
        oy = (TEK_H - ph) // 2
        oy = 0 if oy < 0

        ph.times do |y|
          ty = oy + (ph - 1 - y) # flip: Tek origin is bottom-left
          x = 0
          while x < pw
            unless bits[y][x]
              x += 1
              next
            end
            rl = 1
            while x + rl < pw && bits[y][x + rl]
              rl += 1
            end
            x0 = ox + x
            x1 = ox + x + rl - 1
            io << GS << tek_coord(x0, ty) << tek_coord(x1, ty)
            x += rl
          end
        end

        io << US
        # Leave Tek mode and hand the display back to VT100/ANSI. The storage
        # tube keeps the drawn image in its own window, but without this the
        # next normal screen render (cursor-home/erase/etc.) is emitted *while
        # still in Tek mode* and leaks into the Tek window as stray glyphs
        # (e.g. the "H2J" left over from `ESC[H ESC[2J`).
        io << '\e' << ETX
        io.to_s
      end

      # 4014 10-bit coordinate: HiY, LoY, HiX, LoX.
      private def tek_coord(x : Int32, y : Int32) : String
        String.build do |s|
          s << (0x20 | ((y >> 5) & 0x1f)).chr
          s << (0x60 | (y & 0x1f)).chr
          s << (0x20 | ((x >> 5) & 0x1f)).chr
          s << (0x40 | (x & 0x1f)).chr
        end
      end

      private def to_bits(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32) : Array(Array(Bool))
        # Per-pixel luminance buffer (mutable: error diffusion writes into it).
        lum = Array(Array(Float64)).new(ph) do |y|
          rin = bmp[y]
          Array(Float64).new(pw) do |x|
            px = rin[x]?
            px ? 0.2126 * px.r + 0.7152 * px.g + 0.0722 * px.b : 0.0
          end
        end

        out = Array(Array(Bool)).new(ph)
        ph.times do |y|
          row = Array(Bool).new(pw, false)
          pw.times do |x|
            on = lum[y][x] >= @level
            if dither?
              # Floyd–Steinberg error diffusion: push the rounding error onto the
              # not-yet-visited neighbours. On smooth regions (e.g. sky) this gives
              # an irregular, photographic stipple instead of the fixed cross-hatch
              # an ordered (Bayer) matrix tiles across the image.
              err = lum[y][x] - (on ? 255.0 : 0.0)
              lum[y][x + 1] += err * 7.0 / 16.0 if x + 1 < pw
              if y + 1 < ph
                lum[y + 1][x - 1] += err * 3.0 / 16.0 if x > 0
                lum[y + 1][x] += err * 5.0 / 16.0
                lum[y + 1][x + 1] += err * 1.0 / 16.0 if x + 1 < pw
              end
            end
            on = !on if invert?
            row[x] = on
          end
          out << row
        end
        out
      end

      private def teardown
        s = @listener_screen || return
        @ev_rendered.try { |w| s.off ::Crysterm::Event::Rendered, w }
        @ev_rendered = nil
        @listener_screen = nil
      end
    end
  end
end
