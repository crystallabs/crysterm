require "pnggif"
require "./font"

module Crysterm
  # Renders a rectangular region of a `Screen`'s **rendered/drawn** content to an
  # RGBA image and encodes it as a still PNG (or, via `Recorder`, an animated
  # APNG/GIF).
  #
  # It deliberately works on what the *terminal* shows — the screen's flushed
  # cell buffer (`Screen#lines`) plus the in-band terminal-graphics backends
  # (`Media::Graphics`: sixel / kitty / iterm / regis), whose pixels are
  # composited from each widget's current source frame. Content painted by an
  # external helper (`Media::Overlay` / `Media::Ueberzug`) or shown in a separate
  # window (`Media::Tek`) is *not* visible to the terminal and is omitted — the
  # include/exclude decision is the `Media::Base#capture_pixels?` predicate.
  #
  # Text cells are drawn with a fixed bitmap `Font` (Terminus by default), so a
  # capture is deterministic and independent of the user's real terminal font.
  module Capture
    # Foreground/background used for cells whose color is "terminal default"
    # (`-1`). Chosen to look like a typical light-on-dark terminal.
    DEFAULT_FG = 0xC0C0C0
    DEFAULT_BG = 0x000000

    # Renders cells [*xi*,*xl*) × [*yi*,*yl*) of *screen* into an RGBA
    # `PNGGIF::Bitmap`. *font*/*bold_font* set the glyphs (and thus the pixel
    # size of each cell); *default_fg*/*default_bg* fill terminal-default colors.
    def self.render(screen : Screen, xi : Int32, xl : Int32, yi : Int32, yl : Int32,
                    font : Font = Font.default_normal,
                    bold_font : Font = Font.default_bold,
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

      # 1) Text cells from the rendered buffer. The region walk (skip
      #    continuation halves, bounds-safe) is shared with `Dump.text` via
      #    `Screen#each_content_cell`; here each visible cell is rasterized.
      screen.each_content_cell(xi, xl, yi, yl) do |cell, rx, ry|
        draw_cell canvas, cell, rx * cw, ry * ch, cw, ch,
          font, bold_font, default_fg, default_bg, cell.width
      end

      # 2) Terminal-native graphics, composited over the text exactly as the
      #    terminal stacks them.
      graphics_layers(screen).each do |w|
        layer = w.capture_layer(cw, ch)
        next unless layer
        bmp, cxi, cyi = layer
        composite canvas, bmp, (cxi - xi) * cw, (cyi - yi) * ch
      end

      canvas
    end

    # Renders the region and encodes it as a still PNG.
    def self.png(screen : Screen, xi : Int32, xl : Int32, yi : Int32, yl : Int32,
                 font : Font = Font.default_normal,
                 bold_font : Font = Font.default_bold,
                 default_fg : Int32 = DEFAULT_FG,
                 default_bg : Int32 = DEFAULT_BG) : Bytes
      PNGGIF.encode_png render(screen, xi, xl, yi, yl, font, bold_font, default_fg, default_bg)
    end

    # Flattens *bmp* to raw interleaved RGBA bytes (`w*h*4`), the format a video
    # encoder ingests as `-f rawvideo -pixel_format rgba`. Combined with `render`
    # this is the per-frame payload to append to an `ffmpeg` stdin stream.
    def self.rgba(bmp : PNGGIF::Bitmap) : Bytes
      h = bmp.size
      w = h > 0 ? bmp[0].size : 0
      buf = Bytes.new(w * h * 4)
      i = 0
      bmp.each do |row|
        row.each do |px|
          buf[i] = px.r.to_u8!
          buf[i + 1] = px.g.to_u8!
          buf[i + 2] = px.b.to_u8!
          buf[i + 3] = px.a.to_u8!
          i += 4
        end
      end
      buf
    end

    # Builds the `ffmpeg` argv that reads rawvideo (rgba, *vw*×*vh*, at *fps*) from
    # stdin and encodes it to format *fmt*, writing to *path* (the file extension
    # selects the muxer) or to stdout (`pipe:1`, which needs an explicit `-f`).
    # *loops* sets the gif/apng loop count (0 = infinite). *extra* is appended
    # verbatim for power users. Used by `Screen#capture` for every non-PNG /
    # animated output; still PNG is encoded in-process and never reaches here.
    def self.ffmpeg_args(vw : Int32, vh : Int32, fps : Int32, fmt : String,
                         path : String?, loops : Int32, extra : Array(String)?) : Array(String)
      a = ["-hide_banner", "-loglevel", "error", "-y",
           "-f", "rawvideo", "-pixel_format", "rgba",
           "-video_size", "#{vw}x#{vh}", "-framerate", "#{fps}",
           "-i", "pipe:0"]
      a.concat extra if extra

      case fmt
      when "gif"
        # A generated palette + dithering looks far better than the default 216.
        a.concat ["-filter_complex", "[0:v]split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", loops.to_s]
      when "apng"
        a.concat ["-plays", loops.to_s]
      when "mp4", "mov", "m4v", "mkv"
        a.concat ["-pix_fmt", "yuv420p"] # broad player compatibility
      end

      if path
        a << path
      else
        # Streaming to stdout needs the muxer named explicitly; fragmented MP4 so
        # it doesn't need to seek back to write the moov atom.
        a.concat ["-movflags", "+frag_keyframe+empty_moov"] if {"mp4", "mov", "m4v"}.includes?(fmt)
        a.concat ["-f", fmt, "pipe:1"]
      end
      a
    end

    # ---- internals -----------------------------------------------------------

    private def self.rgb(c : Int32) : PNGGIF::Pixel
      PNGGIF::Pixel.new((c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff, 255)
    end

    # Draws one cell's background, glyph and line decorations into *canvas* at
    # pixel origin (*px*,*py*). Cell size is *cw*×*ch* (the normal font's). A
    # *cols*-column-wide cell (a full-width / 2-column grapheme, e.g. CJK) spans
    # `cols * cw` pixels: its trailing continuation half carries no cell of its
    # own (`each_content_cell` skips it), so the lead cell must paint the whole
    # span here — both its background and the right half of a wide glyph (which
    # the default Unifont renders at 16 px for full-width characters). Clamped to
    # the canvas so a wide cell at the region's right edge can't overflow.
    private def self.draw_cell(canvas, cell, px : Int32, py : Int32, cw : Int32, ch : Int32,
                               font : Font, bold_font : Font, default_fg : Int32, default_bg : Int32,
                               cols : Int32 = 1)
      code = cell.attr
      flags = Attr.flags(code)
      fg = Attr.unpack_color(Attr.fg(code))
      bg = Attr.unpack_color(Attr.bg(code))
      fg = default_fg if fg == -1
      bg = default_bg if bg == -1
      fg, bg = bg, fg if (flags & Attr::REVERSE) != 0

      fgpx = rgb(fg)
      bgpx = rgb(bg)

      # Pixel span of this cell, clamped to the canvas width (the continuation
      # half of a wide cell at the far edge may fall outside the region).
      pw = canvas[0].size
      span = cw * (cols < 1 ? 1 : cols)
      avail = pw - px
      span = avail if span > avail

      # Background fill.
      ch.times do |gy|
        row = canvas[py + gy]
        span.times { |gx| row[px + gx] = bgpx }
      end

      # Glyph (skipped when invisible).
      if (flags & Attr::INVISIBLE) == 0
        glyph = ((flags & Attr::BOLD) != 0 ? bold_font : font).glyph(cell.char.to_s)
        gh = Math.min(ch, glyph.size)
        gh.times do |gy|
          grow = glyph[gy]
          crow = canvas[py + gy]
          gw = Math.min(span, grow.size)
          gw.times { |gx| crow[px + gx] = fgpx if grow.unsafe_fetch(gx) == 1 }
        end
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

    # Alpha-blends *bmp* onto *canvas* with its top-left at pixel (*ox*,*oy*),
    # clipping to the canvas bounds.
    private def self.composite(canvas, bmp : PNGGIF::Bitmap, ox : Int32, oy : Int32)
      ph = canvas.size
      pw = ph > 0 ? canvas[0].size : 0
      bmp.size.times do |y|
        cy = oy + y
        next if cy < 0 || cy >= ph
        srow = bmp[y]
        drow = canvas[cy]
        srow.size.times do |x|
          cx = ox + x
          next if cx < 0 || cx >= pw
          sp = srow.unsafe_fetch(x)
          a = sp.a
          next if a <= 0
          if a >= 255
            drow[cx] = PNGGIF::Pixel.new(sp.r, sp.g, sp.b, 255)
          else
            dp = drow.unsafe_fetch(cx)
            ia = 255 - a
            drow[cx] = PNGGIF::Pixel.new(
              (sp.r * a + dp.r * ia) // 255,
              (sp.g * a + dp.g * ia) // 255,
              (sp.b * a + dp.b * ia) // 255,
              255)
          end
        end
      end
    end

    # All terminal-native graphics widgets under *node* (depth-first), i.e. those
    # whose pixels the terminal itself draws and that opt in via `capture_pixels?`.
    private def self.graphics_layers(node) : Array(Widget::Media::Base)
      acc = [] of Widget::Media::Base
      collect_graphics node, acc
      acc
    end

    private def self.collect_graphics(node, acc : Array(Widget::Media::Base)) : Nil
      node.children.each do |child|
        # A hidden subtree is not shown by the terminal — a hidden widget's
        # `_render` is skipped, so neither its cells nor (for an in-band graphics
        # backend) its escape sequence is ever emitted — so it must not appear in
        # a capture either. `capture_layer` already guards a graphics widget's OWN
        # `visible?` flag, but NOT its ancestors': a widget inside a hidden
        # container (e.g. a non-current tab page, or a `hide`-n parent) is itself
        # flag-visible yet off-screen, and was still composited into the capture —
        # so a capture showed an image the live terminal does not. The text path
        # never had this bug (hidden widgets simply aren't painted into the cell
        # buffer `each_content_cell` walks); this brings the graphics path in line.
        # Pruning the walk at any hidden node drops the whole off-screen subtree,
        # matching the tree-aware `displayed_in_tree?` used by mouse hit-testing
        # and focus traversal.
        next unless child.visible?
        acc << child if child.is_a?(Widget::Media::Base) && child.capture_pixels?
        collect_graphics child, acc
      end
    end
  end
end
