require "./box"

module Crysterm
  class Widget
    # Renders a PNG / APNG / GIF image as colored terminal cells, ported from
    # Blessed's `ansiimage` element.
    #
    # Unlike `Widget::OverlayImage` (which paints a true-color image *over* the
    # terminal via the external `w3mimgdisplay` helper), `ANSIImage` decodes the
    # image itself — using the pure-Crystal `PNGGIF::PNG` reader — and draws it
    # into the normal cell grid. Each pixel of the downscaled image becomes one
    # cell whose background is that pixel's color, so the result is portable to
    # any TrueColor terminal with no external dependencies.
    #
    # Because Crysterm renders in TrueColor, pixel RGB values are used directly;
    # there is no 256-color palette-matching step as in Blessed.
    #
    # ```
    # img = Widget::ANSIImage.new file: "picture.png", width: 30, parent: screen
    # ```
    #
    # Animated images (APNG, animated GIF) play automatically unless `animate:
    # false` is passed; `#play`, `#pause` and `#stop` control playback.
    class ANSIImage < Box
      # Path (or URL, fetched via `curl`/`wget`) of the loaded image.
      property file : String?

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

      # The cellmap currently being displayed (one `PNGGIF::Pixel` per terminal cell).
      property cellmap : PNGGIF::Bitmap?

      # Pre-composited animation frames (`{cellmap, delay_ms}`), if animated.
      @anim_frames : Array(Tuple(PNGGIF::Bitmap, Int32))? = nil
      @playing = false
      @anim_index = 0

      def initialize(
        @file = nil,
        @scale : Float64 = 1.0,
        @animate : Bool = true,
        @ascii : Bool = false,
        @speed : Float64 = 1.0,
        @cell_aspect : Float64 = 2.0,
        # Accepted but ignored: these are `OverlayImage`-specific options. They
        # exist here only so the `Widget::Image` factory — which forwards the
        # same option bag to whichever backend `type` selects — can be called
        # with overlay options without a compile error. ANSIImage scales via
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
      # `Widget::OverlayImage#load`, so code (and the `Widget::Image` factory's
      # union return type) can call `load` on either image backend.
      def load(file : String)
        set_image file
      end

      # Loads and decodes *file*, building the cellmap (and starting playback for
      # animated images when `animate` is on). On failure, shows an error string
      # as content instead of raising.
      def set_image(file : String)
        @file = file

        data : String | Bytes = file
        if file =~ /^https?:/
          data = self.class.fetch(file)
        end

        # Use the widget's configured pixel size as the cellmap target, if given
        # as concrete integers (percentage/auto sizes fall back to `scale`).
        cw = @width.as?(Int32)
        ch = @height.as?(Int32)

        begin
          set_content ""
          png = PNGGIF::PNG.new(data, scale: @scale, cell_width: cw, cell_height: ch, ascii: @ascii, speed: @speed, cell_aspect: @cell_aspect)
          @img = png

          # When the widget size wasn't fixed, adopt the image's cell size so the
          # box shrinks to fit (mirrors Blessed setting width/height from the
          # cellmap dimensions).
          self.width = png.cellmap[0]?.try(&.size) || 0 if cw.nil?
          self.height = png.cellmap.size if ch.nil?

          if png.frames && animate?
            play
          else
            @cellmap = png.cellmap
          end
        rescue ex
          set_content "Image Error: #{ex.message}"
          @img = nil
          @cellmap = nil
        end
      end

      # Clears the loaded image, leaving the widget empty.
      def clear_image
        stop
        set_content ""
        @img = nil
        @cellmap = nil
        @anim_frames = nil
      end

      # Starts (or resumes) animation playback for an animated image.
      def play
        png = @img
        return unless png
        return if @playing

        frames = @anim_frames ||= begin
          cw = @width.as?(Int32)
          ch = @height.as?(Int32)
          png.animation_cellmaps(cw, ch, @scale)
        end
        return unless frames && !frames.empty?

        @playing = true
        spawn animate_loop(frames)
      end

      # Pauses animation playback on the current frame.
      def pause
        @playing = false
      end

      # Stops animation playback and resets to the first frame.
      def stop
        @playing = false
        @anim_index = 0
        if frames = @anim_frames
          @cellmap = frames[0]?.try(&.[0])
        end
      end

      # Background fiber that advances animation frames. Honours `speed` and the
      # image's loop count (`num_plays`; 0 = loop forever).
      private def animate_loop(frames : Array(Tuple(PNGGIF::Bitmap, Int32)))
        png = @img
        num_plays = png ? png.num_plays : 0
        plays = 0
        while @playing
          cm, delay = frames[@anim_index]
          @cellmap = cm
          screen.render

          @anim_index += 1
          if @anim_index >= frames.size
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

        cm = @cellmap
        return coords unless cm

        lines = screen.lines
        xi = coords.xi + ileft
        xl = coords.xl - iright
        yi = coords.yi + itop
        yl = coords.yl - ibottom

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
        rgb = (px.r << 16) | (px.g << 8) | px.b

        if ascii?
          ch, fg = ascii_glyph px, a
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
    end

    alias Ansiimage = ANSIImage
  end
end
