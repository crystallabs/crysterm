require "../image"
require "term_colors"
require "../box"

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
    # false` is passed; `#play`, `#pause` and `#stop` control playback.
    class Image::Ansi < Box
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

      # Path (or URL, fetched via `curl`/`wget`) of the loaded image.
      property file : String?

      # Color depth used to render pixels (see `ColorMode`).
      property colors : ColorMode

      # Scale factor used when neither `width` nor `height` is set on the widget.
      property scale : Float64

      # Whether to play animated images automatically.
      property? animate : Bool

      # Render glyphs by luminance (ASCII-art look) instead of solid blocks.
      property? ascii : Bool

      # Playback speed multiplier for animations (1.0 = native speed).
      property speed : Float64

      # Terminal cell height-to-width ratio, used to keep the image's aspect
      # ratio correct on non-square cells (~2.0 for typical monospace fonts). A
      # value of `1.0` assumes square cells. Changing it after construction takes
      # effect on the next `#set_image`.
      property cell_aspect : Float64

      # The decoded image, or `nil` if loading failed.
      getter img : PNGGIF::PNG?

      # How a still image is fit into a box whose size may vary (see `Image::Fit`).
      # Animated images currently render at their load-time size.
      property fit : Image::Fit

      # The cellmap currently being displayed (one `PNGGIF::Pixel` per terminal cell).
      property cellmap : PNGGIF::Bitmap?

      # Full-resolution composited animation frames (`{bitmap, delay_ms}`),
      # decoded once — the resolution-independent source for playback.
      @src_frames : Array(Tuple(PNGGIF::Bitmap, Int32))? = nil
      # Per-frame cellmaps already sampled for the *current* box size, filled
      # lazily as each frame is shown. Cleared when the box size changes, so a
      # resize only re-samples the frames actually displayed (not all of them).
      @frame_cache = {} of Int32 => PNGGIF::Bitmap
      @playing = false
      @anim_index = 0

      # Whether the loaded image is animated (its frames drive `@cellmap`).
      @animated = false
      # Cell box the cellmap / frame cache was last sampled for, so resize
      # re-samples (and invalidates the per-frame cache).
      @rendered_size : Tuple(Int32, Int32)?

      def initialize(
        @file = nil,
        @scale : Float64 = 1.0,
        @animate : Bool = true,
        @ascii : Bool = false,
        @speed : Float64 = 1.0,
        @cell_aspect : Float64 = 2.0,
        @colors : ColorMode = ColorMode::TrueColor,
        @fit : Image::Fit = Image::Fit::Stretch,
        # Accepted but ignored: these are `Image::Overlay`-specific options. They
        # exist here only so the `Widget::Image` factory — which forwards the
        # same option bag to whichever backend `type` selects — can be called
        # with overlay options without a compile error. Image::Ansi scales via
        # `scale`/`width`/`height` and has no separate stretch/center modes.
        stretch = false,
        center = false,
        **box,
      )
        # Blessed sets `options.shrink = true`; the Crysterm equivalent is
        # `resizable`, so the widget sizes itself to the image when no explicit
        # width/height is given.
        super(**box.merge(resizable: true))

        @file.try { |f| set_image f }

        # Blessed clears this widget's region on every screen `prerender` to keep
        # translucent pixels from blending with the previous frame's. Crysterm's
        # `Screen#_render` already resets the whole cell buffer to the default
        # attr before compositing each frame, so that self-blend can't happen and
        # no per-widget clear is needed here.

        on(::Crysterm::Event::Destroy) { stop }
      end

      # Loads *file*, an alias for `#set_image`. Provides API parity with
      # `Widget::Image::Overlay#load`, so code (and the `Widget::Image` factory's
      # union return type) can call `load` on either image backend.
      def load(file : String)
        set_image file
      end

      # Loads and decodes *file*, building the cellmap (and starting playback for
      # animated images when `animate` is on). On failure, shows an error string
      # as content instead of raising.
      def set_image(file : String)
        @file = file
        cw = @width.as?(Int32)
        ch = @height.as?(Int32)

        set_content ""
        # Decode once at native resolution via the shared `Image.decode` cache
        # (the resolution-independent source); sized renders are derived from
        # `png.bmp` on demand, so a resize re-samples instead of re-decoding.
        png = Image.decode file
        unless png
          set_content "Image Error: could not load #{file}"
          @img = nil
          @cellmap = nil
          @animated = false
          return
        end

        @img = png
        @cellmap = nil
        @src_frames = nil
        @frame_cache.clear
        @anim_index = 0
        @rendered_size = nil
        @animated = !png.frames.nil? && animate?

        # Size the widget to a native-scaled render when no explicit size was
        # given; `#render` (re)samples (still or per-frame) to the actual box.
        if cw.nil? || ch.nil?
          native = png.create_cellmap(png.bmp, scale: @scale, cell_aspect: @cell_aspect)
          self.width = (native[0]?.try(&.size) || 0) if cw.nil?
          self.height = native.size if ch.nil?
        end

        play if @animated
      end

      # Clears the loaded image, leaving the widget empty.
      def clear_image
        stop
        set_content ""
        @img = nil
        @cellmap = nil
        @src_frames = nil
        @frame_cache.clear
        @animated = false
        @rendered_size = nil
      end

      # Index of the frame currently shown. The internal animation loop advances
      # it, but it can also be set directly (after `#pause`) to drive playback
      # from an external clock — e.g. to keep several images in lockstep.
      property anim_index : Int32

      # Whether the composited source frames have been built yet (the heavy
      # decode/composite happens in a background fiber on first `#play`). Once
      # true, the animation loop is actually advancing frames — useful to a
      # recorder that wants to start capturing only after playback is underway.
      def frames_ready? : Bool
        !@src_frames.nil?
      end

      # Starts (or resumes) animation playback. The source frames are composited
      # once (capped resolution) — in a background fiber the first time, so a
      # large GIF doesn't block construction/first paint — then each shown frame
      # is sampled to the current box lazily in `#render`.
      def play
        png = @img
        return unless png
        return if @playing
        @playing = true

        if @src_frames
          spawn animate_loop
        else
          spawn do
            Fiber.yield # let the current layout paint before the heavy build
            sw, sh = Image::Fitting.source_size png
            frames = @src_frames = png.animation_cellmaps(sw, sh, 1.0)
            if frames && !frames.empty? && @playing
              animate_loop
            else
              @playing = false
            end
          end
        end
      end

      # Pauses animation playback on the current frame.
      def pause
        @playing = false
      end

      # Stops animation playback and resets to the first frame.
      def stop
        @playing = false
        @anim_index = 0
      end

      # Background fiber that advances the frame index over time and triggers a
      # render (which samples the current frame to the current box). Honours
      # `speed` and the image's loop count (`num_plays`; 0 = loop forever).
      private def animate_loop
        src = @src_frames
        return unless src
        png = @img
        num_plays = png ? png.num_plays : 0
        plays = 0
        while @playing
          screen.render

          delay = src[@anim_index]?.try(&.[1]) || 100
          @anim_index += 1
          if @anim_index >= src.size
            @anim_index = 0
            plays += 1
            break if num_plays > 0 && plays >= num_plays
          end

          ms = (delay / @speed).to_i
          ms = 1 if ms < 1
          sleep ms.milliseconds
        end
        @playing = false
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

      def render
        coords = _render
        return unless coords

        lines = screen.lines
        xi = coords.xi + ileft
        xl = coords.xl - iright
        yi = coords.yi + itop
        yl = coords.yl - ibottom

        # Resize support: (re)sample the source to the current content box when
        # it changes. For animation, only the *currently shown* frame is sampled
        # (and cached per size), so resizing doesn't regenerate every frame.
        if (img = @img)
          cols = xl - xi
          rows = yl - yi
          if cols > 0 && rows > 0
            if @rendered_size != {cols, rows}
              @rendered_size = {cols, rows}
              @frame_cache.clear
              @cellmap = nil unless @animated
            end
            if @animated
              if (src = @src_frames) && (sf = src[@anim_index]?)
                frame = @frame_cache[@anim_index]?
                if frame.nil?
                  frame = Image::Fitting.compose(img, sf[0], cols, rows, @fit, @cell_aspect)
                  @frame_cache[@anim_index] = frame if frame
                end
                @cellmap = frame if frame
              end
            elsif @cellmap.nil?
              @cellmap = Image::Fitting.compose(img, cols, rows, @fit, @cell_aspect)
            end
          end
        end

        cm = @cellmap
        return coords unless cm

        (yi...yl).each do |y|
          yy = y - yi
          cmrow = cm[yy]?
          next unless cmrow
          row = lines[y]?
          next unless row

          (xi...xl).each do |x|
            xx = x - xi
            px = cmrow[xx]?
            next unless px
            cell = row[x]?
            next unless cell

            a = px.a / 255.0
            next if a == 0.0 # fully transparent: leave the cell as-is

            paint_cell cell, px, a
          end
          row.dirty = true
        end

        coords
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
    end
  end
end
