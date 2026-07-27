require "pnggif"
require "./font"

module Crysterm
  # Renders a rectangular region of a `Window`'s rendered content to an RGBA
  # image and encodes it as a still PNG (or, via `Recorder`, an animated
  # APNG/GIF).
  #
  # Works on what the *terminal* shows: the flushed cell buffer (`Window#lines`)
  # plus the in-band terminal-graphics backends (`Media::Graphics`: sixel /
  # kitty / iterm / regis). Content via an external helper (`Media::Overlay` /
  # `Media::Ueberzug`) or a separate window (`Media::Tek`) is not visible to the
  # terminal and is omitted; `Media::Base#capture_pixels?` is the predicate.
  #
  # Text cells use a fixed bitmap `BitmapFont` (Terminus by default), so a capture is
  # deterministic regardless of the user's real terminal font.
  module Capture
    # Fg/bg for cells with "terminal default" color (`-1`); light-on-dark.
    DEFAULT_FG = 0xC0C0C0
    DEFAULT_BG = 0x000000

    # Renders cells [*xi*,*xl*) × [*yi*,*yl*) of *window* into an RGBA
    # `PNGGIF::Bitmap`. *font*/*bold_font* set the glyphs (and the cell pixel
    # size); *default_fg*/*default_bg* fill terminal-default colors.
    def self.render(window : Window, xi : Int32, xl : Int32, yi : Int32, yl : Int32,
                    font : BitmapFont = BitmapFont.default_normal,
                    bold_font : BitmapFont = BitmapFont.default_bold,
                    default_fg : Int32 = DEFAULT_FG,
                    default_bg : Int32 = DEFAULT_BG) : PNGGIF::Bitmap
      cw = font.width
      ch = font.height
      cols = xl - xi
      rows = yl - yi
      raise ArgumentError.new("Capture.render: empty region") if cols <= 0 || rows <= 0
      pw = cols * cw
      ph = rows * ch

      bg0 = rgb(default_bg)
      canvas = Array(Array(PNGGIF::Pixel)).new(ph) { Array(PNGGIF::Pixel).new(pw, bg0) }

      # Terminal-native graphics stack either under or over the text, per the
      # terminal's own compositing (e.g. a Kitty placement with negative `z`
      # draws under text). Split so each group lands on its own side of the
      # text pass below.
      under, over = graphics_layers(window).partition &.capture_under_text?

      composite_layers canvas, under, xi, yi, cw, ch

      # Text cells from the rendered buffer. The artificial cursor lives only
      # in the flushed output stream, so overlay its cell here or a capture
      # would silently omit it.
      window.each_content_cell(xi, xl, yi, yl) do |cell, rx, ry|
        ov = window.capture_cursor_overlay(rx + xi, ry + yi)
        draw_cell canvas, cell, rx * cw, ry * ch, cw, ch,
          font, bold_font, default_fg, default_bg, cell.width,
          attr_override: ov.try(&.[0]), char_override: ov.try(&.[1])
      end

      composite_layers canvas, over, xi, yi, cw, ch

      canvas
    end

    # Composites each layer widget's captured bitmap onto `canvas`, offset to the
    # captured region's top-left cell `(xi, yi)`.
    private def self.composite_layers(canvas, layers, xi, yi, cw, ch)
      layers.each do |w|
        layer = w.capture_layer(cw, ch)
        next unless layer
        bmp, cxi, cyi = layer
        composite canvas, bmp, (cxi - xi) * cw, (cyi - yi) * ch
      end
    end

    # Renders the region and encodes it as a still PNG.
    def self.png(window : Window, xi : Int32, xl : Int32, yi : Int32, yl : Int32,
                 font : BitmapFont = BitmapFont.default_normal,
                 bold_font : BitmapFont = BitmapFont.default_bold,
                 default_fg : Int32 = DEFAULT_FG,
                 default_bg : Int32 = DEFAULT_BG) : Bytes
      PNGGIF.encode_png render(window, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
    end

    # Flattens *bmp* to raw interleaved RGBA bytes (`w*h*4`), the per-frame
    # payload for an `ffmpeg` stdin stream. The generic implementation lives in
    # pnggif (`PNGGIF::Raster.rgba`).
    def self.rgba(bmp : PNGGIF::Bitmap) : Bytes
      PNGGIF::Raster.rgba bmp
    end

    # Builds the `ffmpeg` argv that reads rawvideo (rgba, *vw*×*vh*, at *fps*) from
    # stdin and encodes it to format *fmt*, writing to *path* or to stdout
    # (`pipe:1`, which needs an explicit `-f`). *loops* sets the gif/apng loop
    # count (0 = infinite). *extra* is appended verbatim.
    def self.ffmpeg_args(vw : Int32, vh : Int32, fps : Int32, fmt : String,
                         path : String?, loops : Int32, extra : Array(String)?) : Array(String)
      a = ["-hide_banner", "-loglevel", "error", "-y",
           "-f", "rawvideo", "-pixel_format", "rgba",
           "-video_size", "#{vw}x#{vh}", "-framerate", "#{fps}",
           "-i", "pipe:0"]
      a.concat extra if extra

      case fmt
      when "gif"
        # A generated palette + dithering looks better than the default 216.
        a.concat ["-filter_complex", "[0:v]split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", loops.to_s]
      when "apng"
        a.concat ["-plays", loops.to_s]
      when "mp4", "mov", "m4v", "mkv"
        a.concat ["-pix_fmt", "yuv420p"] # broad player compatibility
      end

      if path
        a << path
      else
        # Stdout needs the muxer named explicitly; fragmented MP4 avoids seeking
        # back to write the moov atom.
        a.concat ["-movflags", "+frag_keyframe+empty_moov"] if {"mp4", "mov", "m4v"}.includes?(fmt)
        a.concat ["-f", fmt, "pipe:1"]
      end
      a
    end

    # ---- internals -----------------------------------------------------------

    private def self.rgb(c : Int32) : PNGGIF::Pixel
      r, g, b = Colors.rgb_channels(c)
      PNGGIF::Pixel.new(r, g, b, 255)
    end

    # Draws one cell's background, glyph and line decorations into *canvas* at
    # pixel origin (*px*,*py*). A *cols*-column-wide cell (full-width / 2-column
    # grapheme, e.g. CJK) spans `cols * cw` pixels: its continuation half
    # carries no cell (`each_content_cell` skips it), so the lead cell paints
    # the whole span. Clamped to the canvas so a wide cell at the right edge
    # can't overflow.
    private def self.draw_cell(canvas, cell, px : Int32, py : Int32, cw : Int32, ch : Int32,
                               font : BitmapFont, bold_font : BitmapFont, default_fg : Int32, default_bg : Int32,
                               cols : Int32 = 1, attr_override : Int64? = nil, char_override : Char? = nil)
      code = attr_override || cell.attr
      flags = Attr.flags(code)
      raw_fg = Attr.unpack_color(Attr.fg(code))
      raw_bg = Attr.unpack_color(Attr.bg(code))
      reversed = (flags & Attr::REVERSE) != 0
      # Resolve the terminal-default sentinels (-1) *before* applying REVERSE:
      # a real terminal swaps the *resolved* defaults (SGR 7 on default colors
      # renders a light bar with a dark glyph), so swapping the raw sentinels
      # would resolve them post-swap exactly as for a non-reversed cell and
      # lose reverse video entirely for default-colored cells.
      fg = raw_fg == -1 ? default_fg : raw_fg
      bg = raw_bg == -1 ? default_bg : raw_bg
      fg, bg = bg, fg if reversed
      # Whether the background fill may be skipped: only a *non-reversed* cell
      # with a raw default background is pixel-identical to the pre-filled
      # canvas. A reversed cell's effective background is the (resolved) fg
      # color — it paints opaquely and must cover any under-text graphics
      # layer, matching what the terminal shows.
      bg_is_default = !reversed && raw_bg == -1

      fgpx = rgb(fg)
      bgpx = rgb(bg)

      # Pixel span of this cell, clamped to the canvas width.
      pw = canvas[0].size
      span = cw * (cols < 1 ? 1 : cols)
      avail = pw - px
      span = avail if span > avail

      # Background fill, skipped for a default-background cell: the canvas is
      # already pre-filled with default_bg, so this is pixel-identical there
      # and, where an under-text graphics layer exists (negative-z Kitty
      # background), lets it show through exactly as the terminal renders it.
      unless bg_is_default
        ch.times do |gy|
          row = canvas[py + gy]
          span.times { |gx| row[px + gx] = bgpx }
        end
      end

      # INVISIBLE (concealed) must suppress every foreground mark, not just the
      # glyph: a drawn underline/strikethrough would reveal the hidden text's
      # presence and width (e.g. a masked password field).
      if (flags & Attr::INVISIBLE) == 0
        glyph = ((flags & Attr::BOLD) != 0 ? bold_font : font).glyph((char_override || cell.char).to_s)
        gh = Math.min(ch, glyph.size)
        gh.times do |gy|
          grow = glyph[gy]
          crow = canvas[py + gy]
          gw = Math.min(span, grow.size)
          gw.times { |gx| crow[px + gx] = fgpx if grow.unsafe_fetch(gx) == 1 }
        end

        # Line decorations.
        if (flags & Attr::UNDERLINE) != 0
          row = canvas[py + ch - 1]
          span.times { |gx| row[px + gx] = fgpx }
        end
        if (flags & Attr::STRIKE) != 0
          row = canvas[py + ch // 2]
          span.times { |gx| row[px + gx] = fgpx }
        end
      end
    end

    # Alpha-blends *bmp* onto *canvas* with its top-left at pixel (*ox*,*oy*),
    # clipping to the canvas bounds. The generic implementation lives in pnggif
    # (`PNGGIF::Raster.composite`).
    private def self.composite(canvas, bmp : PNGGIF::Bitmap, ox : Int32, oy : Int32)
      PNGGIF::Raster.composite canvas, bmp, ox, oy
    end

    # All terminal-native graphics widgets under *node* (depth-first) that opt in
    # via `capture_pixels?`.
    private def self.graphics_layers(node) : Array(Widget::Media::Base)
      acc = [] of Widget::Media::Base
      collect_graphics node, acc
      acc
    end

    private def self.collect_graphics(node, acc : Array(Widget::Media::Base)) : Nil
      node.children.each do |child|
        # A hidden subtree isn't shown by the terminal, so it must not appear in a
        # capture. `capture_layer` guards a graphics widget's own `visible?` flag
        # but not its ancestors': a widget inside a hidden container (non-current
        # tab page, hidden parent) is flag-visible yet off-window. Pruning the
        # walk at any hidden node drops the whole subtree.
        next unless child.visible?
        acc << child if child.is_a?(Widget::Media::Base) && child.capture_pixels?
        collect_graphics child, acc
      end
    end
  end

  # The ffmpeg process plumbing behind `Window#capture`, kept beside
  # `Capture.ffmpeg_args`/`.render`/`.rgba` (the encoder pieces it drives).
  class Window
    # Records the region for *duration*, sampling the current cell buffer on a
    # fixed `1/fps` wall-clock grid, piping raw RGBA to ffmpeg.
    private def capture_animation(xi, xl, yi, yl, fmt, path, duration, fps, loops,
                                  font, bold_font, default_fg, default_bg, ffmpeg_args) : Bytes?
      # This render is not just a measurement: it is handed to
      # `#feed_animation_frames` as frame 0, which would otherwise render the
      # identical region a second time immediately afterwards (a full
      # `ph × pw` RGBA canvas plus a glyph blit per cell, twice back-to-back).
      first = Capture.render(self, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
      vw = first[0]?.try(&.size) || 0
      vh = first.size

      run_ffmpeg(vw, vh, fps, fmt, path, loops, ffmpeg_args) do |input|
        feed_animation_frames(input, xi, xl, yi, yl, duration, fps,
          font, bold_font, default_fg, default_bg, first)
      end
    end

    # Spawns ffmpeg for the given output, yields its stdin for frame writing, then
    # finalizes: closes stdin, collects stdout bytes (when no *path*), and reaps
    # the process. Returns the encoded bytes (no path) or nil (wrote to path).
    private def run_ffmpeg(vw, vh, fps, fmt, path, loops, ffmpeg_args, &) : Bytes?
      raise "Crysterm capture: empty frame (#{vw}x#{vh})" if vw <= 0 || vh <= 0
      args = Capture.ffmpeg_args(vw, vh, fps, fmt, path, loops, ffmpeg_args)
      devnull = File.open(File::NULL, "w")
      proc =
        begin
          Process.new("ffmpeg", args,
            input: Process::Redirect::Pipe,
            output: path ? devnull : Process::Redirect::Pipe,
            error: devnull)
        rescue ex
          devnull.close
          raise "Crysterm capture: ffmpeg required for format #{fmt.inspect} (#{ex.message})"
        end

      # Drain stdout concurrently (when capturing bytes) so a full pipe can't
      # deadlock against our frame writes.
      out_ch = nil
      if path.nil?
        out_ch = Channel(Bytes).new
        spawn { out_ch.try &.send(proc.output.getb_to_end) }
      end

      # Not useless: the only real assignment is inside the `ensure`, and Crystal
      # requires this initializer for the read after the block to compile
      # ("read before assignment to local variable 'result'"). Ameba (>= 1.7)
      # flags it anyway, so the directive is load-bearing, not decoration.
      result = nil # ameba:disable Lint/UselessAssign
      begin
        yield proc.input
      ensure
        # Reap the process and close fds even if the frame-writing block raised,
        # else an exception leaves a zombie ffmpeg and an open `/dev/null` fd.
        # Closing stdin first sends EOF so ffmpeg exits and the drain completes.
        proc.input.close rescue nil
        result = out_ch.try &.receive
        proc.wait
        devnull.close
      end
      result
    end
  end
end
