require "./cells"

module Crysterm
  class Widget
    # Renders an image into terminal cells at *sub-cell* resolution, using the
    # several Unicode glyph families that pack more than one sub-pixel into a
    # single character. This is parallel to `Image::Ansi` (and, like it, decodes
    # with the pure-Crystal PNGGIF reader and supports animated GIF/APNG); it
    # differs in that one cell can carry several sub-pixels:
    #
    #   Block     1x1   one cell per pixel (bg color)          (≈ Image::Ansi)
    #   Ascii     1x1   luminance glyph + fg                   (≈ Image::Ansi ascii)
    #   Half      1x2   `▀` with fg = top pixel, bg = bottom   (full color, 2x res)
    #   Quadrant  2x2   `▘▌▚▙█…` block elements (2 colors)     (4x res)
    #   Sextant   2x3   `🬀…` U+1FB00 sextants (2 colors)        (6x res)
    #   Octant    2x4   `𜺀…` U+1CD00 octants (2 colors)         (8x res)
    #   Braille   2x4   `⠿` 8 dots, single fg color            (8x res, monochrome/cell)
    #
    # ```
    # img = Widget::Image::Glyph.new file: "pic.png", mode: :braille, width: 40, height: 12, parent: screen
    # img.mode = Widget::Image::Glyph::Mode::Octant # re-renders in another family
    # ```
    class Image::Glyph < Image::Cells
      enum Mode
        Block
        Ascii
        Half
        Quadrant
        Sextant
        Octant
        Braille

        # Sub-cell grid (columns, rows) packed into one character for this mode.
        def subgrid : Tuple(Int32, Int32)
          case self
          in Block, Ascii    then {1, 1}
          in Half            then {1, 2}
          in Quadrant        then {2, 2}
          in Sextant         then {2, 3}
          in Octant, Braille then {2, 4}
          end
        end
      end

      getter mode : Mode

      # Minimum local luminance gradient (sum of |dx|+|dy|) for a cell to be
      # treated as an edge in `Ascii` mode and get a glyph.
      ASCII_EDGE = 28

      def initialize(@file = nil, @mode : Mode = Mode::Half, @animate : Bool = true,
                     @speed : Float64 = 1.0, @fit : Image::Fit = Image::Fit::Stretch, **box)
        super(**box)
        @file.try { |f| set_image f }
        on(::Crysterm::Event::Destroy) { stop }
      end

      # The decoded image (alias for the shared `#source`), or `nil` if none.
      def img : PNGGIF::PNG?
        source
      end

      # Switches glyph family; the next render re-samples at the new sub-cell
      # resolution (rebuilding animation frames if the image is animated).
      def mode=(m : Mode)
        return if m == @mode
        @mode = m
        @rendered_size = nil
        if @animated
          @file.try { |f| set_image f }
        else
          request_render
        end
      end

      def self.fetch(url : String) : Bytes
        Widget::Image::Ansi.fetch url
      end

      # Sample at the current mode's sub-cell resolution (cells × sub-grid).
      protected def compose(img : PNGGIF::PNG, cols : Int32, rows : Int32, frame : PNGGIF::Bitmap?) : PNGGIF::Bitmap?
        sx, sy = @mode.subgrid
        if frame
          Image::Fitting.compose(img, frame, cols * sx, rows * sy, @fit, 1.0)
        else
          Image::Fitting.compose(img, cols * sx, rows * sy, @fit, 1.0)
        end
      end

      protected def draw_sample(bmp : PNGGIF::Bitmap, xi : Int32, xl : Int32, yi : Int32, yl : Int32)
        lines = screen.lines
        sx, sy = @mode.subgrid

        # Braille is one colour per cell, so it needs a single global on/off
        # threshold (a per-cell threshold would just produce ~50% noise).
        thr = @mode.braille? ? global_threshold(bmp) : 0.0

        (yi...yl).each do |y|
          cy = y - yi
          row = lines[y]?
          next unless row
          (xi...xl).each do |x|
            cx = x - xi
            cell = row[x]?
            next unless cell
            paint cell, bmp, cx, cy, sx, sy, thr
          end
          row.dirty = true
        end
      end

      private def paint(cell, sub, cx, cy, sx, sy, thr)
        case @mode
        in Mode::Block
          px = pix(sub, cx, cy) || return
          cell.char = ' '
          cell.attr = Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(rgb_of px))
        in Mode::Ascii
          # Edge-aware ASCII: every cell keeps the pixel's full color, but an
          # ASCII glyph is overlaid ONLY where there is a real edge (high local
          # contrast). The glyph traces the edge direction (- | / \), so it adds
          # detail where it helps instead of dumping a character into every cell.
          px = pix(sub, cx, cy) || return
          bg = rgb_of px
          l = lum px
          gx = neighbor_lum(sub, cx + 1, cy, l) - neighbor_lum(sub, cx - 1, cy, l)
          gy = neighbor_lum(sub, cx, cy + 1, l) - neighbor_lum(sub, cx, cy - 1, l)
          if gx.abs + gy.abs < ASCII_EDGE
            cell.char = ' '
            cell.attr = Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(bg))
          else
            fg = l < 128 ? 0xf0f0f0 : 0x101010
            cell.char = edge_char(gx, gy)
            cell.attr = Attr.pack(0, Attr.pack_color(fg), Attr.pack_color(bg))
          end
        in Mode::Half
          top = pix(sub, cx * 1 + 0, cy * 2 + 0)
          bot = pix(sub, cx * 1 + 0, cy * 2 + 1)
          return unless top
          bcol = bot || top
          cell.char = '▀'
          cell.attr = Attr.pack(0, Attr.pack_color(rgb_of top), Attr.pack_color(rgb_of bcol))
        in Mode::Quadrant, Mode::Sextant, Mode::Octant
          paint_two_color cell, sub, cx, cy, sx, sy
        in Mode::Braille
          paint_braille cell, sub, cx, cy, thr
        end
      end

      # Two-colour modes: split this cell's sub-pixels into "ink" (brighter than
      # the cell mean) and "paper", pick the glyph for the ink pattern, and use
      # the average ink/paper colours as fg/bg.
      private def paint_two_color(cell, sub, cx, cy, sx, sy)
        mean = 0.0
        count = 0
        sy.times do |dy|
          sx.times do |dx|
            if p = pix(sub, cx * sx + dx, cy * sy + dy)
              mean += lum p
              count += 1
            end
          end
        end
        return if count == 0
        mean /= count

        mask = 0
        fr = fg_ = fb = 0; fn = 0
        br = bg_ = bb = 0; bn = 0
        bit = 1
        sy.times do |dy|
          sx.times do |dx|
            p = pix(sub, cx * sx + dx, cy * sy + dy)
            if p && lum(p) >= mean
              mask |= bit
              fr += p.r; fg_ += p.g; fb += p.b; fn += 1
            elsif p
              br += p.r; bg_ += p.g; bb += p.b; bn += 1
            end
            bit <<= 1
          end
        end

        fg = fn > 0 ? ((fr // fn) << 16) | ((fg_ // fn) << 8) | (fb // fn) : 0
        bg = bn > 0 ? ((br // bn) << 16) | ((bg_ // bn) << 8) | (bb // bn) : fg

        cell.char = glyph_for mask, sx, sy
        cell.attr = Attr.pack(0, Attr.pack_color(fg), Attr.pack_color(bg))
      end

      private def paint_braille(cell, sub, cx, cy, thr)
        mask = 0
        r = g = b = 0; n = 0
        4.times do |dy|
          2.times do |dx|
            p = pix(sub, cx * 2 + dx, cy * 4 + dy)
            next unless p
            if lum(p) >= thr
              mask |= BRAILLE_BITS[dx][dy]
              r += p.r; g += p.g; b += p.b; n += 1
            end
          end
        end
        if n == 0
          cell.char = ' '
          cell.attr = Attr.pack(0, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT)
        else
          fg = ((r // n) << 16) | ((g // n) << 8) | (b // n)
          cell.char = (0x2800 + mask).chr
          cell.attr = Attr.pack(0, Attr.pack_color(fg), Attr::COLOR_DEFAULT)
        end
      end

      # ---------------------------------------------------------------- helpers

      private def pix(sub, c, r) : PNGGIF::Pixel?
        sub[r]?.try &.[c]?
      end

      private def lum(px : PNGGIF::Pixel) : Float64
        0.2126 * px.r + 0.7152 * px.g + 0.0722 * px.b
      end

      # Luminance of a neighbour sub-pixel, or *fallback* when out of bounds (so
      # the image border doesn't read as a strong edge).
      private def neighbor_lum(sub, c, r, fallback : Float64) : Float64
        if p = pix(sub, c, r)
          lum p
        else
          fallback
        end
      end

      # ASCII glyph tracing an edge, given the luminance gradient (gx, gy). The
      # edge runs perpendicular to the gradient.
      private def edge_char(gx : Float64, gy : Float64) : Char
        deg = Math.atan2(gy, gx) * 180.0 / Math::PI
        deg += 180.0 if deg < 0
        if deg < 22.5 || deg >= 157.5
          '|'
        elsif deg < 67.5
          '/'
        elsif deg < 112.5
          '-'
        else
          '\\'
        end
      end

      private def rgb_of(px : PNGGIF::Pixel) : Int32
        (px.r << 16) | (px.g << 8) | px.b
      end

      private def global_threshold(sub) : Float64
        total = 0.0
        count = 0
        sub.each do |line|
          line.each do |px|
            total += lum px
            count += 1
          end
        end
        count == 0 ? 128.0 : total / count
      end

      private def glyph_for(mask, sx, sy) : Char
        if sx == 2 && sy == 2
          QUADRANT[mask]
        elsif sx == 2 && sy == 3
          SEXTANT[mask]
        else
          OCTANT[mask]
        end
      end

      # Bit value for braille dot at sub-cell (dx, dy); standard Unicode layout.
      BRAILLE_BITS = [
        [0x01, 0x02, 0x04, 0x40], # col 0 : rows 0..3
        [0x08, 0x10, 0x20, 0x80], # col 1 : rows 0..3
      ]

      # 2x2 quadrant glyphs by mask (TL=1, TR=2, BL=4, BR=8).
      QUADRANT = [
        ' ', '▘', '▝', '▀', '▖', '▌', '▞', '▛',
        '▗', '▚', '▐', '▜', '▄', '▙', '▟', '█',
      ]

      # 2x3 sextants (U+1FB00..), 2x4 octants (U+1CD00..). Both are binary-ordered
      # over their sub-cells, skipping the patterns that already exist as block
      # elements (empty/full/left-half/right-half, plus top/bottom-half for octants).
      SEXTANT = begin
        arr = Array(Char).new(64, ' ')
        idx = 0
        (0..63).each do |m|
          arr[m] =
            case m
            when  0 then ' '
            when 21 then '▌' # left column
            when 42 then '▐' # right column
            when 63 then '█'
            else
              c = (0x1FB00 + idx).chr
              idx += 1
              c
            end
        end
        arr
      end

      OCTANT = begin
        arr = Array(Char).new(256, ' ')
        skip = {0 => ' ', 255 => '█', 15 => '▀', 240 => '▄', 85 => '▌', 170 => '▐'}
        idx = 0
        (0..255).each do |m|
          arr[m] =
            if s = skip[m]?
              s
            else
              c = (0x1CD00 + idx).chr
              idx += 1
              c
            end
        end
        arr
      end
    end
  end
end
