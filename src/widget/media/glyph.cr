require "../../widget_media_cells"

module Crysterm
  class Widget
    # Renders an image into terminal cells at *sub-cell* resolution, using
    # Unicode glyph families that pack more than one sub-pixel into a single
    # character. Parallel to `Media::Ansi` (same PNGGIF decoder, same animated
    # GIF/APNG support), but one cell can carry several sub-pixels:
    #
    #   Block     1x1   one cell per pixel (bg color)          (≈ Media::Ansi)
    #   Ascii     1x1   luminance glyph + fg                   (≈ Media::Ansi ascii)
    #   Half      1x2   `▀` with fg = top pixel, bg = bottom   (full color, 2x res)
    #   Quadrant  2x2   `▘▌▚▙█…` block elements (2 colors)     (4x res)
    #   Sextant   2x3   `🬀…` U+1FB00 sextants (2 colors)        (6x res)
    #   Octant    2x4   `𜺀…` U+1CD00 octants (2 colors)         (8x res)
    #   Braille   2x4   `⠿` 8 dots, single fg color            (8x res, monochrome/cell)
    #
    # ```
    # img = Widget::Media::Glyph.new file: "pic.png", mode: :braille, width: 40, height: 12, parent: window
    # img.mode = Widget::Media::Glyph::Mode::Octant # re-renders in another family
    # ```
    #
    # <!-- widget-examples:capture v1 -->
    # ![Glyph screenshot](../../../tests/widget/media/glyph/glyph.5s.apng)
    # <!-- /widget-examples:capture -->
    class Media::Glyph < Media::Cells
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

      # The highest-resolution *colour* glyph mode the terminal supports, for
      # callers that want maximum detail without hard-coding a family that may
      # render as `?`. Walks the resolution ladder — `Octant` (2×4) → `Sextant`
      # (2×3) → `Quadrant` (2×2, universally supported block elements) — using
      # the terminal's separately-gated legacy-computing capabilities (see
      # `Tput::Emulator#legacy_computing_octant?` / `#legacy_computing_sextant?`),
      # or `Ascii` when the terminal has no Unicode at all. `Braille` is excluded
      # — it is monochrome, not a colour family. *tput* defaults to the global
      # window's; with no terminal handle the optimistic `Octant` is returned.
      def self.best_mode(tput : ::Tput? = nil) : Mode
        tput ||= (Crysterm::Window.total > 0 ? Crysterm::Window.global.tput : nil)
        return Mode::Octant unless tp = tput
        return Mode::Ascii unless tp.features.unicode?
        emu = tp.emulator
        return Mode::Octant if emu.legacy_computing_octant?
        return Mode::Sextant if emu.legacy_computing_sextant?
        Mode::Quadrant
      end

      # Whether to key dots on *opacity* rather than luminance. Normally a
      # `Braille` dot is on where the image is bright (luminance threshold), but
      # for vector content on a transparent canvas (`Graph::Canvas`) a dark
      # stroke should still be a dot. With this on, a dot is on iff its pixel is
      # opaque, using that pixel's own color.
      property? alpha_key : Bool = false

      # Minimum local luminance gradient (sum of |dx|+|dy|) for a cell to be
      # treated as an edge in `Ascii` mode and get a glyph.
      ASCII_EDGE = 28

      def initialize(@file = nil, @mode : Mode = Mode::Half, animate : Bool | Timer = true,
                     @speed : Float64 = 1.0, @fit : Media::Fit = Media::Fit::Stretch, **box)
        super(**box)
        setup_animate animate # before set_image, so shared clock is known when play subscribes
        @file.try { |f| set_image f }
        on(::Crysterm::Event::Destroy) { stop }
      end

      # The decoded image (alias for the shared `#source`), or `nil` if none.
      def img : PNGGIF::PNG?
        source
      end

      # Cell box times this mode's sub-cell grid (e.g. 2x4 for braille/octant),
      # so a `Graph::Canvas` bitmap maps one pixel per sub-cell dot, no resampling.
      def native_resolution(cols : Int32, rows : Int32) : Tuple(Int32, Int32)
        sx, sy = @mode.subgrid
        {cols * sx, rows * sy}
      end

      # A sub-cell pixel is `(cell_w/sx) x (cell_h/sy)`; with the terminal's
      # measured cell aspect (`CSS::Length.cell_aspect_ratio`) this is square for
      # braille/octant (2x4) and half (1x2), wide for block/quadrant.
      def native_pixel_aspect : Float64
        sx, sy = @mode.subgrid
        car = Crysterm::CSS::Length.cell_aspect_ratio
        car = 2.0 if car <= 0
        sy / (car * sx)
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
        Widget::Media::Ansi.fetch url
      end

      # Sample at the current mode's sub-cell resolution (cells × sub-grid).
      protected def compose(img : PNGGIF::PNG, cols : Int32, rows : Int32, frame : PNGGIF::Bitmap?) : PNGGIF::Bitmap?
        sx, sy = @mode.subgrid
        # Sub-pixel aspect (height/width): a cell is `car`:1 tall (measured cell
        # height/width, see `CSS::Length.cell_aspect_ratio`), split into sx
        # columns x sy rows, giving a sub-pixel (1/sx) wide x (car/sy) tall. Only
        # square when sy == car*sx; otherwise passing 1.0 would distort the fit
        # and change the image size per mode. Correction factor is car*sx/sy.
        car = Crysterm::CSS::Length.cell_aspect_ratio
        car = 2.0 if car <= 0
        am = car * sx / sy
        Media::Fitting.compose(img, frame, cols * sx, rows * sy, @fit, am, sx, sy)
      end

      protected def draw_sample(bmp : PNGGIF::Bitmap, xi : Int32, xl : Int32, yi : Int32, yl : Int32)
        lines = window.lines
        sx, sy = @mode.subgrid

        # Braille is one color per cell, so it needs a single global on/off
        # threshold (per-cell would just produce ~50% noise). Skipped under
        # `#alpha_key?`, where opacity drives the dots instead.
        thr = (@mode.braille? && !alpha_key?) ? @threshold_memo.get(anim_index, bmp) { global_threshold bmp } : 0.0

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
          blend_cell cell, ' ', Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(rgb_of px)), px.a / 255.0
        in Mode::Ascii
          # Edge-aware ASCII: every cell keeps the pixel's full color, but an
          # ASCII glyph tracing the edge direction (- | / \) is overlaid only
          # where local contrast is high, instead of every cell.
          px = pix(sub, cx, cy) || return
          a = px.a / 255.0
          bg = rgb_of px
          l = lum px
          gx = neighbor_lum(sub, cx + 1, cy, l) - neighbor_lum(sub, cx - 1, cy, l)
          gy = neighbor_lum(sub, cx, cy + 1, l) - neighbor_lum(sub, cx, cy - 1, l)
          if gx.abs + gy.abs < ASCII_EDGE
            blend_cell cell, ' ', Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(bg)), a
          else
            fg = l < 128 ? 0xf0f0f0 : 0x101010
            blend_cell cell, edge_char(gx, gy), Attr.pack(0, Attr.pack_color(fg), Attr.pack_color(bg)), a
          end
        in Mode::Half
          top = pix(sub, cx, cy * 2 + 0)
          bot = pix(sub, cx, cy * 2 + 1)
          return unless top
          # Sub-pixels become fg (top) and bg (bottom); opacity is their mean
          # alpha (missing bottom reuses top's).
          at = top.a / 255.0
          ab = bot ? bot.a / 255.0 : at
          # A transparent half carries no real colour (it's black in the source),
          # so borrow the opaque half's colour rather than bleeding black into a
          # letterbox row or edge; the cell still fades out via its lower mean
          # alpha. Mirrors the `paint_two_color` transparency handling.
          tcol = at > 0 ? top : (bot || top)
          bcol = (bot && ab > 0) ? bot : top
          blend_cell cell, '▀', Attr.pack(0, Attr.pack_color(rgb_of tcol), Attr.pack_color(rgb_of bcol)), (at + ab) / 2.0
        in Mode::Quadrant, Mode::Sextant, Mode::Octant
          paint_two_color cell, sub, cx, cy, sx, sy
        in Mode::Braille
          paint_braille cell, sub, cx, cy, thr
        end
      end

      # Two-color modes: split this cell's sub-pixels into "ink" (brighter than
      # the cell mean) and "paper", pick the glyph for the ink pattern, and use
      # the average ink/paper colors as fg/bg.
      private def paint_two_color(cell, sub, cx, cy, sx, sy)
        # Sub-pixels (<= 2x4 = 8) cached on the stack in the first pass so the
        # second pass skips re-fetching `pix` and recomputing `lum` — the
        # per-cell hot spot of the multi-column modes. Enumeration is row-major
        # (dy outer, dx inner), so cache slot `i` carries mask bit `1 << i`.
        pixels = uninitialized StaticArray(PNGGIF::Pixel, 8)
        lums = uninitialized StaticArray(Float64, 8)
        # `opaque[i]` gates the ink/paper split: only sub-pixels with alpha > 0
        # carry a real colour. A fully-transparent sub-pixel — a letterbox
        # margin (`Fit::Contain`) or a hole in the source (GIF/PNG alpha) — is
        # stored as black `(0,0,0,0)`, so counting it would drag the luminance
        # mean down and average black into the paper (bg) colour, leaving a
        # dark fringe along the image's edges and letterbox rows. Instead its
        # only contribution is to the cell's coverage (`asum`/`count` below),
        # which fades the cell out through its alpha — matching how `Media::Ansi`
        # and `Mode::Braille` already drop transparent pixels.
        opaque = uninitialized StaticArray(Bool, 8)
        mean = 0.0 # mean luminance of the *opaque* sub-pixels only
        opq = 0    # opaque sub-pixel count
        count = 0  # in-bounds sub-pixel count (opaque or not), for coverage
        asum = 0.0
        i = 0
        sy.times do |dy|
          # Fetch this sub-row once, then index columns off it (instead of a
          # `sub[r]?` row lookup + nil check per sub-pixel via `pix`).
          row0 = sub[cy * sy + dy]?
          sx.times do |dx|
            if row0 && (p = row0[cx * sx + dx]?)
              count += 1
              asum += p.a
              if p.a > 0
                l = lum p
                pixels[i] = p
                lums[i] = l
                opaque[i] = true
                mean += l
                opq += 1
              else
                opaque[i] = false
              end
            else
              opaque[i] = false
            end
            i += 1
          end
        end
        return if count == 0       # no in-bounds sub-pixels (letterbox): leave the cell
        a = (asum / 255.0) / count # cell opacity = mean alpha of its sub-pixels
        return if opq == 0         # all in-bounds sub-pixels transparent: nothing to draw
        mean /= opq

        mask = 0
        fr = fg_ = fb = 0; fn = 0
        br = bg_ = bb = 0; bn = 0
        n = sx * sy
        j = 0
        while j < n
          if opaque[j]
            p = pixels[j]
            if lums[j] >= mean
              mask |= (1 << j)
              fr += p.r; fg_ += p.g; fb += p.b; fn += 1
            else
              br += p.r; bg_ += p.g; bb += p.b; bn += 1
            end
          end
          j += 1
        end

        fg = fn > 0 ? ((fr // fn) << 16) | ((fg_ // fn) << 8) | (fb // fn) : 0
        bg = bn > 0 ? ((br // bn) << 16) | ((bg_ // bn) << 8) | (bb // bn) : fg

        blend_cell cell, glyph_for(mask, sx, sy), Attr.pack(0, Attr.pack_color(fg), Attr.pack_color(bg)), a
      end

      private def paint_braille(cell, sub, cx, cy, thr)
        mask = 0
        r = g = b = 0; n = 0
        on_asum = 0.0  # alpha of the *lit* dots only
        off_asum = 0.0 # alpha of the unlit in-bounds dots
        total = 0
        4.times do |dy|
          # Fetch this sub-row once, then index columns off it (rather than a
          # `sub[r]?` row lookup + nil check per dot via `pix`).
          row0 = sub[cy * 4 + dy]?
          next unless row0
          2.times do |dx|
            p = row0[cx * 2 + dx]?
            next unless p
            total += 1
            on = alpha_key? ? p.a >= 128 : lum(p) >= thr
            if on
              mask |= BRAILLE_BITS[dx][dy]
              r += p.r; g += p.g; b += p.b; n += 1
              on_asum += p.a
            else
              off_asum += p.a
            end
          end
        end
        return if total == 0 # no in-bounds sub-pixels (letterbox): leave the cell
        if n == 0
          # No lit dots: blank cell, opacity is unlit pixels' mean alpha (so a
          # transparent region leaves the cell untouched).
          blend_cell cell, ' ', Attr.pack(0, Attr::COLOR_DEFAULT, Attr::COLOR_DEFAULT), (off_asum / 255.0) / total
        else
          # Opacity is the mean alpha of the *lit* dots only: unlit dots are
          # already conveyed by the glyph (bit off), so including them would
          # dilute the lit color toward a muddy, non-matching tint.
          a = (on_asum / 255.0) / n
          fg = ((r // n) << 16) | ((g // n) << 8) | (b // n)
          blend_cell cell, (0x2800 + mask).chr, Attr.pack(0, Attr.pack_color(fg), Attr::COLOR_DEFAULT), a
        end
      end

      # ---------------------------------------------------------------- helpers

      private def pix(sub, c, r) : PNGGIF::Pixel?
        sub[r]?.try &.[c]?
      end

      private def lum(px : PNGGIF::Pixel) : Float64
        Media.luminance px
      end

      # Luminance of a neighboring sub-pixel, or *fallback* when out of bounds
      # (so the image border doesn't read as a strong edge).
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

      # Memoizes the braille on/off threshold (whole-bitmap luminance mean) per
      # animation frame index, so a looping animation reuses each frame's
      # threshold across loops instead of recomputing it every frame; a still uses
      # index 0 (see `FrameMemo`). Cleared via `#clear_frame_derived` wherever the
      # base drops `@frame_cache`.
      @threshold_memo = FrameMemo(Float64).new

      protected def clear_frame_derived(idx : Int32? = nil)
        if idx
          @threshold_memo.delete idx
        else
          @threshold_memo.clear
        end
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

      # 2x3 sextants (U+1FB00..1FB3B), 2x4 octants (U+1CD00..1CDE5). Each Unicode
      # block assigns one codepoint per sub-cell pattern in increasing bit-mask
      # order, skipping patterns that already have a character elsewhere (the
      # renderer maps those to the pre-existing glyphs).
      #
      # Bit layout matches `paint_two_color` (LSB = top-left, row-major), so the
      # mask bit for Unicode "BLOCK OCTANT/SEXTANT position N" is `1 << (N-1)`:
      #     pos1=1   pos2=2          pos1=1   pos2=2
      #     pos3=4   pos4=8          pos3=4   pos4=8
      #     pos5=16  pos6=32         pos5=16  pos6=32
      #     (sextant)                pos7=64  pos8=128  (octant)
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

      # The 26 octant patterns Unicode did NOT encode in the Block Octant range
      # (they already exist as half/quadrant/quarter blocks elsewhere). The other
      # 230 masks take U+1CD00..1CDE5 sequentially in mask order. Getting this
      # set wrong both mis-maps glyphs and overruns past U+1CDE5. Verified
      # against Unicode 16.0 UCD ("Symbols for Legacy Computing Supplement").
      OCTANT = begin
        arr = Array(Char).new(256, ' ')
        # mask => pre-existing character (positions filled, per the bit layout above)
        skip = {
            0 => ' ',         # (empty)               SPACE
            1 => '\u{1CEA8}', # 1                     LEFT HALF UPPER ONE QUARTER BLOCK
            2 => '\u{1CEAB}', # 2                     RIGHT HALF UPPER ONE QUARTER BLOCK
            3 => '\u{1FB82}', # 12                    UPPER ONE QUARTER BLOCK
            5 => '▘',         # 13                    QUADRANT UPPER LEFT
           10 => '▝',         # 24                    QUADRANT UPPER RIGHT
           15 => '▀',         # 1234                  UPPER HALF BLOCK
           20 => '\u{1FBE6}', # 35                    MIDDLE LEFT ONE QUARTER BLOCK
           40 => '\u{1FBE7}', # 46                    MIDDLE RIGHT ONE QUARTER BLOCK
           63 => '\u{1FB85}', # 123456                UPPER THREE QUARTERS BLOCK
           64 => '\u{1CEA3}', # 7                     LEFT HALF LOWER ONE QUARTER BLOCK
           80 => '▖',         # 57                    QUADRANT LOWER LEFT
           85 => '▌',         # 1357                  LEFT HALF BLOCK
           90 => '▞',         # 2457                  QUADRANT UPPER RIGHT AND LOWER LEFT
           95 => '▛',         # 123457                QUADRANT UL+UR+LL
          128 => '\u{1CEA0}', # 8                     RIGHT HALF LOWER ONE QUARTER BLOCK
          160 => '▗',         # 68                    QUADRANT LOWER RIGHT
          165 => '▚',         # 1368                  QUADRANT UPPER LEFT AND LOWER RIGHT
          170 => '▐',         # 2468                  RIGHT HALF BLOCK
          175 => '▜',         # 123468                QUADRANT UL+UR+LR
          192 => '\u{2582}',  # 78                     LOWER ONE QUARTER BLOCK
          240 => '▄',         # 5678                  LOWER HALF BLOCK
          245 => '▙',         # 135678                QUADRANT UL+LL+LR
          250 => '▟',         # 245678                QUADRANT UR+LL+LR
          252 => '\u{2586}',  # 345678                 LOWER THREE QUARTERS BLOCK
          255 => '█',         # 12345678              FULL BLOCK
        }
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

    # ---- single-mode backends ------------------------------------------
    # Each concrete widget pins one drawing `Glyph::Mode`, so it can be
    # exemplified and documented on its own; all rendering lives in the shared
    # `Glyph` base, which stays mode-selectable via `mode:`. They are grouped by
    # terminal capability: `Ascii::*` need no Unicode at all (space + 7-bit
    # glyphs), while `Unicode::*` rely on Unicode block/legacy-computing glyphs
    # (see `Glyph.best_mode` for what a given terminal can render).
    module Media::Ascii
      # ASCII contour: full-colour cells with a `- | / \` glyph overlaid only
      # where local contrast is high (edge-aware). Stays on the `Glyph` engine
      # (`Mode::Ascii`) for now — solid ASCII blocks live on the `Ansi` engine
      # as `Ascii::TrueColor`/etc.
      #
      # <!-- widget-examples:capture v1 -->
      # ![Edge screenshot](../../../../tests/widget/media/glyph/edge/edge.5s.apng)
      # <!-- /widget-examples:capture -->
      class Edge < Glyph
        def initialize(**box)
          super **box.merge(mode: Glyph::Mode::Ascii)
        end
      end
    end

    module Media::Unicode
      # <!-- widget-examples:capture v1 -->
      # ![Half screenshot](../../../../tests/widget/media/glyph/half/half.5s.apng)
      # <!-- /widget-examples:capture -->
      class Half < Glyph
        def initialize(**box)
          super **box.merge(mode: Glyph::Mode::Half)
        end
      end

      # <!-- widget-examples:capture v1 -->
      # ![Quadrant screenshot](../../../../tests/widget/media/glyph/quadrant/quadrant.5s.apng)
      # <!-- /widget-examples:capture -->
      class Quadrant < Glyph
        def initialize(**box)
          super **box.merge(mode: Glyph::Mode::Quadrant)
        end
      end

      # <!-- widget-examples:capture v1 -->
      # ![Sextant screenshot](../../../../tests/widget/media/glyph/sextant/sextant.5s.apng)
      # <!-- /widget-examples:capture -->
      class Sextant < Glyph
        def initialize(**box)
          super **box.merge(mode: Glyph::Mode::Sextant)
        end
      end

      # <!-- widget-examples:capture v1 -->
      # ![Octant screenshot](../../../../tests/widget/media/glyph/octant/octant.5s.apng)
      # <!-- /widget-examples:capture -->
      class Octant < Glyph
        def initialize(**box)
          super **box.merge(mode: Glyph::Mode::Octant)
        end
      end

      # <!-- widget-examples:capture v1 -->
      # ![Braille screenshot](../../../../tests/widget/media/glyph/braille/braille.5s.apng)
      # <!-- /widget-examples:capture -->
      class Braille < Glyph
        def initialize(**box)
          super **box.merge(mode: Glyph::Mode::Braille)
        end
      end
    end
  end
end
