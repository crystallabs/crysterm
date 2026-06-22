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
    # An **animated** source (GIF/APNG) plays in the Tek window: each frame is a
    # full PAGE-clear + redraw (the storage tube can't update in place), so it
    # flickers and is heavier than the raster backends — but it works. Animation
    # defaults to ordered (Bayer) dithering because it is *frame-independent*: the
    # same pixels dither identically every frame, so the picture is temporally
    # stable. Error diffusion (the default for a still) would "boil"/shimmer.
    #
    # ```
    # tek = Widget::Image::Tek.new file: "pic.png", parent: screen
    # # the Tek window appears on the next screen render
    # ```
    class Image::Tek < Box
      # 1-bit dithering method.
      enum Dither
        None      # hard threshold at `level` — cleanest spans, fewest vectors
        Ordered   # 4×4 Bayer ordered dither — frame-independent (stable in animation)
        Diffusion # Floyd–Steinberg error diffusion — best for a still; shimmers if animated
        Auto      # Diffusion for a still image, Ordered for an animated one
      end

      # Tektronix 4014 addressable space (10-bit X, ~0..779 visible Y).
      TEK_W = 1024
      TEK_H =  780
      GS    = '\u{1d}' # enter Tek graph (vector) mode
      US    = '\u{1f}' # return to Tek alpha mode
      ETX   = '\u{03}' # with a leading ESC: leave Tek mode, back to VT100/ANSI

      property file : String?

      # Luminance threshold (0..255) used by `None`/`Diffusion`.
      getter level : Float64

      # Which 1-bit dithering method to use (see `Dither`).
      getter dither : Dither

      # Invert ink/paper (draw the dark areas instead of the bright ones).
      getter? invert : Bool

      # Longest image edge, in Tek units, the rendering is scaled to fit.
      getter fit : Int32

      # Play an animated (GIF/APNG) source in the Tek window.
      property? animate : Bool

      # Playback speed multiplier for animations (1.0 = native speed).
      property speed : Float64

      # The Tek display is a separate window that xterm auto-rescales from the
      # 4014 logical coordinate space, so a window/box resize needs no redraw.
      # Changing the *drawing* parameters does, though — these setters re-fire it.
      def level=(v : Float64)
        return if v == @level
        @level = v
        redraw!
      end

      def dither=(v : Dither)
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
        @playing = false # stop any running animation loop first
        @drawn = false
        request_render
      end

      @drawn = false
      @playing = false
      @frames : Array(Tuple(PNGGIF::Bitmap, Int32))?
      @anim_index = 0
      @listener_screen : ::Crysterm::Screen?
      @ev_rendered : ::Crysterm::Event::Rendered::Wrapper?

      def initialize(
        @file = nil,
        @level : Float64 = 128.0,
        dither : Dither | Bool = Dither::Auto,
        @invert : Bool = false,
        @fit : Int32 = 680,
        @animate : Bool = true,
        @speed : Float64 = 1.0,
        # Accepted-and-ignored so the `Widget::Image` factory can forward one
        # common option bag (incl. overlay-only options) to any backend.
        stretch = false,
        center = false,
        **box,
      )
        # Accept a legacy Bool: true ⇒ diffusion (the old "dithered" look), false ⇒ none.
        @dither = dither.is_a?(Bool) ? (dither ? Dither::Diffusion : Dither::None) : dither

        super **box

        # Draw into the Tek window once the screen first renders.
        s = screen
        @listener_screen = s
        @ev_rendered = s.on(::Crysterm::Event::Rendered) { draw_tek }

        on(::Crysterm::Event::Destroy) { teardown }
      end

      def load(file : String)
        @playing = false
        @file = file
        @drawn = false
        @frames = nil
        @anim_index = 0
        request_render
      end

      def set_image(file : String)
        load file
      end

      # Index of the frame currently shown (animation).
      getter anim_index : Int32

      # Switches to the Tek window and draws the image (or starts its animation).
      # Safe to call directly; otherwise it fires once on the first screen render.
      def draw_tek
        return if @drawn
        s = screen? || return
        file = @file || return
        @drawn = true
        start_drawing s, file
      end

      private def start_drawing(s : ::Crysterm::Screen, file : String)
        data : String | Bytes = file
        data = Widget::Image::Ansi.fetch(file) if file =~ /^https?:/

        probe = PNGGIF::PNG.new(data)
        iw = probe.width
        ih = probe.height
        return if iw <= 0 || ih <= 0
        pw, ph = fit_dims iw, ih

        frames = @animate ? PNGGIF::PNG.new(data).animation_cellmaps(pw, ph, 1.0) : nil
        if frames && frames.size > 1
          @frames = frames
          @playing = true
          spawn animate_loop(s)
        else
          png = PNGGIF::PNG.new(data, cell_width: pw, cell_height: ph, cell_aspect: 1.0)
          bmp = png.cellmap
          return if bmp.empty?
          # Enter Tek, draw the one frame, then hand the display back to VT100 so
          # the next normal render doesn't leak into the Tek window (the "H2J"
          # left over from `ESC[H ESC[2J`). The storage tube keeps the picture.
          s.tput._oprint String.build { |io| io << "\e[?38h" << build_frame(bmp) << '\e' << ETX }
          s.tput.flush
        end
      end

      # Plays the decoded frames in the Tek window: enter Tek once, then PAGE-clear
      # + redraw each frame on its own fiber (sleeping per-frame delay), and leave
      # Tek mode when stopped. Loops forever until `#stop`/destroy.
      private def animate_loop(s : ::Crysterm::Screen)
        frames = @frames || return
        s.tput._oprint "\e[?38h" # enter Tek mode for the whole run
        s.tput.flush
        idx = 0
        while @playing
          bmp, delay = frames[idx]
          @anim_index = idx
          s.tput._oprint build_frame(bmp)
          s.tput.flush
          idx = (idx + 1) % frames.size
          ms = (delay / @speed).to_i
          ms = 1 if ms < 1
          sleep ms.milliseconds
        end
        s.tput._oprint "\e\u{03}" rescue nil # ESC ETX: back to VT100
        s.tput.flush rescue nil
      end

      def stop
        @playing = false
      end

      # Longest-edge fit into the addressable Tek space, aspect preserved.
      private def fit_dims(iw : Int32, ih : Int32) : Tuple(Int32, Int32)
        if iw >= ih
          pw = @fit
          ph = (@fit * ih / iw).to_i
        else
          ph = @fit
          pw = (@fit * iw / ih).to_i
        end
        pw = 1 if pw < 1
        ph = 1 if ph < 1
        # If a fitted edge overruns the Tek space, scale *both* down by the same
        # factor (an independent per-axis clamp would squash the aspect ratio).
        if pw > TEK_W
          ph = (ph * TEK_W / pw).to_i
          pw = TEK_W
        end
        if ph > TEK_H
          pw = (pw * TEK_H / ph).to_i
          ph = TEK_H
        end
        {pw < 1 ? 1 : pw, ph < 1 ? 1 : ph}
      end

      # PAGE-clear + the image as horizontal vector runs (no mode enter/exit, so it
      # can be reused per animation frame). Centered in the Tek screen.
      private def build_frame(bmp : PNGGIF::Bitmap) : String
        ph = bmp.size
        pw = bmp[0]?.try(&.size) || 0
        return "\e\u{0c}" if pw == 0 || ph == 0
        bits = to_bits bmp, pw, ph

        ox = (TEK_W - pw) // 2
        ox = 0 if ox < 0
        oy = (TEK_H - ph) // 2
        oy = 0 if oy < 0

        String.build do |io|
          io << "\e\u{0c}" # PAGE: clear the storage tube
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
              io << GS << tek_coord(ox + x, ty) << tek_coord(ox + x + rl - 1, ty)
              x += rl
            end
          end
          io << US
        end
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

      # Resolves `Auto` to a concrete method: ordered (frame-stable) while an
      # animation is loaded, error diffusion (nicer) for a still.
      private def effective_dither : Dither
        return @dither unless @dither.auto?
        @frames ? Dither::Ordered : Dither::Diffusion
      end

      private def to_bits(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32) : Array(Array(Bool))
        mode = effective_dither

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
            case mode
            in Dither::Ordered
              # Threshold against the tiled 4×4 Bayer matrix. Deterministic per
              # pixel ⇒ identical every frame, so animation doesn't shimmer.
              on = lum[y][x] > (Image::BAYER_MATRIX[y & 3][x & 3] + 0.5) / 16.0 * 255.0
            in Dither::Diffusion
              # Floyd–Steinberg: push the rounding error onto the not-yet-visited
              # neighbours — irregular, photographic stipple on smooth areas.
              on = lum[y][x] >= @level
              err = lum[y][x] - (on ? 255.0 : 0.0)
              lum[y][x + 1] += err * 7.0 / 16.0 if x + 1 < pw
              if y + 1 < ph
                lum[y + 1][x - 1] += err * 3.0 / 16.0 if x > 0
                lum[y + 1][x] += err * 5.0 / 16.0
                lum[y + 1][x + 1] += err * 1.0 / 16.0 if x + 1 < pw
              end
            in Dither::None
              on = lum[y][x] >= @level
            in Dither::Auto
              on = lum[y][x] >= @level # unreachable (resolved by effective_dither)
            end
            on = !on if invert?
            row[x] = on
          end
          out << row
        end
        out
      end

      private def teardown
        @playing = false
        s = @listener_screen || return
        @ev_rendered.try { |w| s.off ::Crysterm::Event::Rendered, w }
        @ev_rendered = nil
        @listener_screen = nil
      end
    end
  end
end
