require "../../widget_media_base"
require "../../widget_media_render_hook"

module Crysterm
  class Widget
    # Renders an image in **Tektronix 4014** vector graphics. Emitting `ESC[?38h`
    # switches an xterm built with `--enable-tek4014` into its Tek emulation,
    # which opens a *separate* window (named `tektronix`) and draws on a
    # simulated storage-tube display. This is fundamentally unlike the other
    # image widgets: the Tek display is monochrome (1-bit), vector-only (no
    # raster blit, no partial erase — only a whole-window PAGE), and lives in its
    # own window, so it does NOT share the cell-grid or window-overlay erase
    # lifecycles. It's a deliberate takeover of the display.
    #
    # A photo is therefore dithered to 1 bit and drawn as one run of horizontal
    # vectors per "ink" span — a faithfully retro green-on-black rendering. It
    # fits into the Tek window per the shared `fit` contract (`Media::Fit`),
    # defaulting to `Contain`.
    #
    # An **animated** source (GIF/APNG) plays in the Tek window: each frame is a
    # full PAGE-clear + redraw (the storage tube can't update in place), so it
    # flickers and is heavier than the raster backends — but it works. Because the
    # Tek window is *not* driven by the window render loop, this overrides
    # `Media::Base`'s render-driven animation with its own window loop. Animation
    # defaults to ordered (Bayer) dithering, which is frame-independent (stable);
    # error diffusion (the default for a still) would shimmer.
    #
    # ```
    # tek = Widget::Media::Tek.new file: "pic.png", parent: window
    # # the Tek window appears on the next window render
    # ```
    class Media::Tek < Media::Base
      include Media::RenderHook

      # Tektronix 4014 addressable space (10-bit X, ~0..779 visible Y).
      TEK_W = 1024
      TEK_H =  780
      GS    = '\u{1d}' # enter Tek graph (vector) mode
      US    = '\u{1f}' # return to Tek alpha mode
      ETX   = '\u{03}' # with a leading ESC: leave Tek mode, back to VT100/ANSI

      # Luminance threshold (0..255) used by `None`/`Diffusion`.
      getter level : Float64

      # Which 1-bit dithering method to use (see `Media::Dither`).
      getter dither : Media::Dither

      # Invert ink/paper (draw the dark areas instead of the bright ones).
      getter? invert : Bool

      # The Tek display is a separate window that xterm auto-rescales from the
      # 4014 logical coordinate space, so a window/box resize needs no redraw.
      # Changing the *drawing* parameters does, though — these setters re-fire it.
      # Defines a *name*`=` setter that, on an actual change, stores the value and
      # re-fires the Tek redraw (`#redraw!`). The four drawing-parameter setters
      # (`level`, `dither`, `invert`, `fit`) carried this identical change-guard.
      private macro redraw_setter(name, type)
        def {{name.id}}=(v : {{type}})
          return if v == @{{name.id}}
          @{{name.id}} = v
          redraw!
        end
      end

      redraw_setter level, Float64
      redraw_setter dither, Media::Dither
      redraw_setter invert, Bool
      redraw_setter fit, Media::Fit

      # Forces the image to be re-emitted to the Tek window on the next render.
      private def redraw!
        @playing = false # stop any running animation loop first
        @drawn = false
        request_render
      end

      @drawn = false
      # Generation token for the animation loop, bumped on every (re)start (see
      # `#start_drawing`). A running `#animate_loop` carries the generation it was
      # spawned with and exits as soon as that no longer matches — so a `#redraw!`
      # (from `#load` or a parameter setter) that stops playback and lets the next
      # render spawn a fresh loop can't leave the previous loop running
      # concurrently: `#redraw!` only flips `@playing` false, which the sleeping
      # old fiber would otherwise see flip back to true under it. Exposed for tests.
      getter anim_gen : Int32 = 0

      def initialize(
        @file = nil,
        @level : Float64 = 128.0,
        dither : Media::Dither | Bool = Media::Dither::Auto,
        @invert : Bool = false,
        @fit : Media::Fit = Media::Fit::Contain,
        @animate : Bool = true,
        @speed : Float64 = 1.0,
        **box,
      )
        # Accept a legacy Bool: true ⇒ auto (the old "dithered" look, now
        # still-vs-animation aware), false ⇒ none.
        @dither = dither.is_a?(Bool) ? (dither ? Media::Dither::Auto : Media::Dither::None) : dither

        super **box

        # Draw into the Tek window once the window first renders.
        register_render_hook(window) { draw_tek }

        on(::Crysterm::Event::Destroy) { teardown }
      end

      def load(file : String)
        @playing = false
        @file = file
        @drawn = false
        @src_frames = nil
        @anim_index = 0
        request_render
      end

      def clear_image
        super # stop + clear file/source/frames
        @drawn = false
      end

      # (Re)start drawing/animating in the Tek window.
      def play
        return if @playing
        redraw!
      end

      # Switches to the Tek window and draws the image (or starts its animation).
      # Safe to call directly; otherwise it fires once on the first window render.
      def draw_tek
        return if @drawn
        s = window? || return
        file = @file || return
        @drawn = true
        start_drawing s, file
      end

      private def start_drawing(s : ::Crysterm::Window, file : String)
        data = Media.source_data(file)

        probe = PNGGIF::PNG.new(data)
        iw = probe.width
        ih = probe.height
        return if iw <= 0 || ih <= 0
        # `Media::Fit#layout` already clamps the drawn size to >= 1, so no extra clamp.
        dw, dh, ox, oy = @fit.layout(TEK_W, TEK_H, iw, ih)

        frames = @animate ? probe.animation_cellmaps(dw, dh, 1.0) : nil
        if frames && frames.size > 1
          @src_frames = frames
          @playing = true
          # Bump the generation so any loop still running from a previous draw
          # (one started before a `#load`/setter `#redraw!`) sees a stale
          # generation and exits, instead of running concurrently with — and
          # fighting over the Tek window against — this new loop.
          gen = (@anim_gen += 1)
          spawn animate_loop(s, ox, oy, gen)
        else
          png = PNGGIF::PNG.new(data, cell_width: dw, cell_height: dh, cell_aspect: 1.0)
          bmp = png.cellmap
          return if bmp.empty?
          # Enter Tek, draw the one frame, then hand the display back to VT100 so
          # the next normal render doesn't leak into the Tek window (the "H2J"
          # left over from `ESC[H ESC[2J`). The storage tube keeps the picture.
          s.tput._oprint String.build { |io| io << "\e[?38h" << build_frame(bmp, ox, oy) << '\e' << ETX }
          s.tput.flush
        end
      end

      # Plays the decoded frames in the Tek window: enter Tek once, then PAGE-clear
      # + redraw each frame on its own fiber (sleeping per-frame delay), and leave
      # Tek mode when stopped. Loops forever until `#stop`/destroy.
      private def animate_loop(s : ::Crysterm::Window, ox : Int32, oy : Int32, gen : Int32)
        frames = @src_frames || return
        s.tput._oprint "\e[?38h" # enter Tek mode for the whole run
        s.tput.flush
        idx = 0
        # Exit as soon as a newer loop has taken over (`gen != @anim_gen`), even if
        # `@playing` has been flipped back to true under us by that new loop.
        while @playing && gen == @anim_gen
          bmp, delay = frames[idx]
          @anim_index = idx
          s.tput._oprint build_frame(bmp, ox, oy)
          s.tput.flush
          idx = (idx + 1) % frames.size
          ms = (delay / @speed).to_i
          ms = 1 if ms < 1
          sleep ms.milliseconds
        end
        # Only hand the display back to VT100 if we are still the live loop. A loop
        # that exited because it was superseded must NOT leave Tek mode — that would
        # yank the window out from under the new loop now drawing into it.
        if gen == @anim_gen
          s.tput._oprint "\e\u{03}" rescue nil # ESC ETX: back to VT100
          s.tput.flush rescue nil
        end
      end

      # PAGE-clear + the image as horizontal vector runs (no mode enter/exit, so it
      # can be reused per animation frame), drawn at offset *ox*/*oy* with bounds
      # clipping (so a `Cover` overflow doesn't wrap the 10-bit coordinates).
      private def build_frame(bmp : PNGGIF::Bitmap, ox : Int32, oy : Int32) : String
        ph = bmp.size
        pw = bmp[0]?.try(&.size) || 0
        return "\e\u{0c}" if pw == 0 || ph == 0
        bits = to_bits bmp, pw, ph

        String.build do |io|
          io << "\e\u{0c}" # PAGE: clear the storage tube
          ph.times do |y|
            ty = oy + (ph - 1 - y) # flip: Tek origin is bottom-left
            next if ty < 0 || ty >= TEK_H
            Media.each_run(bits[y], pw) do |ink, x, rl|
              next unless ink # skip a run of paper (non-ink) pixels
              x0 = ox + x
              x1 = ox + x + rl - 1
              x0 = 0 if x0 < 0
              x1 = TEK_W - 1 if x1 > TEK_W - 1
              next if x1 < x0 || x0 > TEK_W - 1
              io << GS << tek_coord(x0, ty) << tek_coord(x1, ty)
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
      private def effective_dither : Media::Dither
        @dither.resolve(!@src_frames.nil?)
      end

      private def to_bits(bmp : PNGGIF::Bitmap, pw : Int32, ph : Int32) : Array(Array(Bool))
        mode = effective_dither

        # Per-pixel luminance buffer (mutable: error diffusion writes into it).
        lum = Array(Array(Float64)).new(ph) do |y|
          rin = bmp[y]
          Array(Float64).new(pw) do |x|
            px = rin[x]?
            px ? Media.luminance(px) : 0.0
          end
        end

        out = Array(Array(Bool)).new(ph)
        ph.times do |y|
          row = Array(Bool).new(pw, false)
          pw.times do |x|
            case mode
            in Media::Dither::Ordered
              # Threshold against the tiled 4×4 Bayer matrix. Deterministic per
              # pixel ⇒ identical every frame, so animation doesn't shimmer.
              on = lum[y][x] > (Media::BAYER_MATRIX[y & 3][x & 3] + 0.5) / 16.0 * 255.0
            in Media::Dither::Diffusion
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
            in Media::Dither::None, Media::Dither::Auto # Auto is resolved away by effective_dither
              on = lum[y][x] >= @level
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
        teardown_render_hook
      end
    end
  end
end
