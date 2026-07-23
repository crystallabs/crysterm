require "./font"
require "./widget/media"

module Crysterm
  class Widget
    module Media
      # ANSI/ASCII **art** file extensions handled by `#decode_ansi` — BBS /
      # "textmode" art: CP437 glyphs plus ANSI SGR + cursor sequences (often with
      # no newlines at all; the layout is done entirely with cursor positioning).
      ANSI_ART_RE = /\.(ans|asc|nfo|diz|ansi)$/i

      # CP437 (DOS OEM) high half, `0x80..0xFF` -> Unicode codepoints. The low
      # half (`0x20..0x7E`) is plain ASCII.
      CP437_HIGH = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
        0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
        0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
        0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
        0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
        0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
        0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
        0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
        0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
        0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
        0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
      ]

      # 16-color ANSI/VGA palette (RGB), indices 0..15 (8..15 = bright).
      ANSI_PALETTE = [
        0x000000, 0xAA0000, 0x00AA00, 0xAA5500, 0x0000AA, 0xAA00AA, 0x00AAAA, 0xAAAAAA,
        0x555555, 0xFF5555, 0x55FF55, 0xFFFF55, 0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF,
      ]

      # Maps a CP437 byte to its Unicode `Char`.
      def self.cp437(b : UInt8) : Char
        case b
        when 0x00..0x1F then ' '
        when 0x7F       then '\u{2302}'
        when 0x20..0x7E then b.unsafe_chr
        else                 CP437_HIGH[b - 0x80].unsafe_chr
        end
      end

      private def self.pal(idx : Int32) : PNGGIF::Pixel
        v = ANSI_PALETTE[idx.clamp(0, 15)]
        r, g, b = rgb24(v)
        PNGGIF::Pixel.new(r, g, b)
      end

      # Parses the `;`- or `:`-separated decimal CSI parameters in `data[ps...j]`
      # into the reused *into* array — one entry per field, an empty field
      # yielding `0` — instead of a `String.new + split + map` per sequence.
      # The parallel *colons* array records, per field, whether the separator
      # before it was a ':' (the ISO 8613-6 / ITU T.416 sub-parameter separator),
      # so extended-colour selectors can tell `38:2::r:g:b` from `38;2;r;g;b`.
      # Matches `"…".split(/[;:]/).map { |p| p.empty? ? 0 : p.to_i }`.
      private def self.parse_csi_params(data : Bytes, ps : Int32, j : Int32, into : Array(Int32), colons : Array(Bool)) : Array(Int32)
        into.clear
        colons.clear
        cur = 0
        sep_colon = false # was the separator before the current field a ':'?
        k = ps
        while k < j
          b = data[k]
          if b == 0x3B || b == 0x3A # ';' or ':'
            into << cur
            colons << sep_colon
            cur = 0
            sep_colon = (b == 0x3A)
          elsif 0x30 <= b <= 0x39
            # Saturate instead of overflowing: a pathological digit run would
            # otherwise raise `OverflowError` on `cur * 10` and abort the whole
            # decode, defeating the clamping (`clampx`/`clampy`) every consumer
            # applies. The cap is far above any real CSI parameter and keeps
            # `cur * 10` in `Int32` range.
            cur = cur < 100_000_000 ? cur * 10 + (b - 0x30) : cur
          end
          k += 1
        end
        into << cur
        colons << sep_colon
        into
      end

      # Resolves an extended-colour SGR selector's sub-parameters (those after a
      # `38`/`48`, starting at *i*) into the nearest 16-colour `ANSI_PALETTE`
      # index (0..15) plus the number of sub-parameters consumed. Handles `5;n`
      # (xterm-256) and `2;r;g;b` (truecolour), in both `;` and `:` forms;
      # malformed/unknown consumes nothing and maps to `nil`. *colons* is the
      # per-field separator flags from `parse_csi_params`.
      private def self.ext_color_index(params : Array(Int32), colons : Array(Bool), i : Int32)
        none = {nil.as(Int32?), 0}
        case params[i]?
        when 5
          n = params[i + 1]?
          return {nil.as(Int32?), 1} unless n
          r, g, b = xterm256_rgb(n)
          {nearest_index(ANSI_PALETTE, r, g, b).as(Int32?), 2}
        when 2
          # The colon form (ISO 8613-6) may carry a leading colorspace-id field:
          # `38:2:<cs>:r:g:b` (cs often empty -> 0). Four colon-separated fields
          # after the `2` means the first is the colorspace id and must be
          # skipped; the `;` form and the abbreviated colon form (`38:2:r:g:b`)
          # keep r at i+1.
          off = colons[i + 1]? && colons[i + 2]? && colons[i + 3]? && colons[i + 4]? ? 1 : 0
          r = (params[i + 1 + off]? || 0).clamp(0, 255)
          g = (params[i + 2 + off]? || 0).clamp(0, 255)
          b = (params[i + 3 + off]? || 0).clamp(0, 255)
          {nearest_index(ANSI_PALETTE, r, g, b).as(Int32?), 4 + off}
        else
          none
        end
      end

      # RGB of an xterm-256 palette index (0..255): the 16 system colours, then
      # the 6×6×6 colour cube, then the 24-step grayscale ramp.
      private def self.xterm256_rgb(n : Int32) : Tuple(Int32, Int32, Int32)
        n = n.clamp(0, 255)
        if n < 16
          rgb24(ANSI_PALETTE[n])
        elsif n < 232
          m = n - 16
          {cube_level(m // 36), cube_level((m // 6) % 6), cube_level(m % 6)}
        else
          gr = (n - 232) * 10 + 8
          {gr, gr, gr}
        end
      end

      # One channel of the xterm-256 6×6×6 cube: 0 maps to 0, levels 1..5 to
      # `55 + level*40` (the standard xterm ramp 95,135,175,215,255).
      private def self.cube_level(c : Int32) : Int32
        c == 0 ? 0 : 55 + c * 40
      end

      # Ink fraction (0..1) of the sub-region of glyph *g* (sized *gw*x*gh*) that
      # maps to sub-pixel (*sx*,*sy*) of an *sw*x*sh* per-cell grid. With sw=sh=1
      # this is the whole-glyph coverage; finer grids give sub-cell shape.
      private def self.subcoverage(g : Array(Array(Int32)), gw : Int32, gh : Int32,
                                   sx : Int32, sw : Int32, sy : Int32, sh : Int32) : Float64
        return 0.0 if gw == 0 || gh == 0
        x0 = sx * gw // sw
        x1 = {(sx + 1) * gw // sw, x0 + 1}.max
        y0 = sy * gh // sh
        y1 = {(sy + 1) * gh // sh, y0 + 1}.max
        lit = 0
        tot = 0
        (y0...y1).each do |yy|
          row = g[yy]?
          (x0...x1).each do |xx|
            tot += 1
            lit += 1 if row && row[xx]? == 1
          end
        end
        tot > 0 ? lit.to_f / tot : 0.0
      end

      # Linear blend of *fg* over *bg* by *cov* (0 = bg, 1 = fg).
      private def self.blend(fg : PNGGIF::Pixel, bg : PNGGIF::Pixel, cov : Float64) : PNGGIF::Pixel
        inv = 1.0 - cov
        PNGGIF::Pixel.new(
          (fg.r * cov + bg.r * inv).round.to_i,
          (fg.g * cov + bg.g * inv).round.to_i,
          (fg.b * cov + bg.b * inv).round.to_i)
      end

      # ANSI.SYS autowrap column count for *data*: the character width recorded in
      # a trailing SAUCE record (a 128-byte metadata footer, id `"SAUCE00"`, whose
      # `TInfo1` field holds the column count for Character-type files), or 80 when
      # no valid SAUCE record is present. Guarded so a bogus/zero width can't shrink
      # the canvas below the classic default.
      protected def self.sauce_ansi_width(data : Bytes) : Int32
        default = 80
        return default if data.size < 128
        rec = data.size - 128
        # id "SAUCE" + version "00"
        return default unless data[rec] == 0x53 && data[rec + 1] == 0x41 &&
                              data[rec + 2] == 0x55 && data[rec + 3] == 0x43 &&
                              data[rec + 4] == 0x45
        # DataType (offset 94) must be 1 (Character) for TInfo1 to mean width.
        return default unless data[rec + 94] == 1
        # TInfo1 (offset 96): little-endian UInt16 = character width.
        width = data[rec + 96].to_i | (data[rec + 97].to_i << 8)
        width > 0 ? width : default
      end

      # Decodes BBS / "textmode" ANSI art (*data*: CP437 bytes + ANSI escapes)
      # into a pixel bitmap, wrapped as a still `PNGGIF::PNG` so the ordinary
      # Media output backends (Ansi/Glyph/Sixel/Kitty/…) render it like any other
      # image. An **input decoder**, a peer of `PNGGIF` — it never writes to the
      # terminal itself.
      #
      # Runs a small self-contained ANSI interpreter (no terminal/emulator): a 2D
      # cell grid honoring SGR colour/bold and cursor motion (CUP/CUU/CUD/CUF/CUB,
      # CR/LF, ED), then each cell is rasterized with the bitmap `BitmapFont`.
      # ameba:disable Metrics/CyclomaticComplexity
      def self.decode_ansi(data : Bytes, font : BitmapFont = BitmapFont.default_normal) : PNGGIF::PNG
        # cell = {char, fg(0..7|nil), fg_bright, bg(0..7|nil), bg_bright, reverse}
        cells = {} of Tuple(Int32, Int32) => Tuple(Char, Int32?, Bool, Int32?, Bool, Bool)
        x = 0; y = 0; maxx = 0; maxy = 0
        fg = nil.as(Int32?); fgb = false; bg = nil.as(Int32?); bgb = false; rev = false
        sx = 0; sy = 0
        # ANSI.SYS-style autowrap width: classic BBS art omits CR/LF on full-width
        # rows and relies entirely on the terminal wrapping at the right margin.
        # Honour a trailing SAUCE record's character width (TInfo1) when present,
        # else the ANSI.SYS default of 80. Only sequential printing wraps —
        # explicit cursor positioning (CUP/CUF) is left unwrapped.
        wrap_width = sauce_ansi_width data
        clampx = ->(v : Int32) { v.clamp(0, 1000) }
        clampy = ->(v : Int32) { v.clamp(0, 4000) }
        # Relative-motion count (CUU/CUD/CUF/CUB): an omitted *or* zero parameter
        # means 1. Params are pre-mapped so a missing value arrives as 0 (not nil),
        # and 0 is truthy in Crystal, so `|| 1` alone wouldn't catch it.
        amt = ->(v : Int32?) { n = v || 1; n < 1 ? 1 : n }

        # Reused across every CSI so the parameter list isn't reallocated per
        # sequence; consumed fully within each iteration before the next reparse.
        # `colon_flags` runs parallel to `nums` (per-field ':'-separator flags).
        nums = [] of Int32
        colon_flags = [] of Bool

        i = 0
        n = data.size
        while i < n
          b = data[i]
          if b == 0x1B && data[i + 1]? == 0x5B # CSI: ESC [
            j = i + 2
            # Optional private-marker prefix (`<`,`=`,`>`,`?`), e.g. `ESC[?7h`
            # autowrap, `ESC[?25l` hide cursor. Must be consumed so trailing
            # bytes aren't mis-rendered as text; carries no meaning here.
            priv = j < n && 0x3C <= data[j] <= 0x3F
            j += 1 if priv
            ps = j
            while j < n && (data[j] == 0x3B || data[j] == 0x3A || (0x30 <= data[j] <= 0x39))
              j += 1
            end
            parse_csi_params(data, ps, j, nums, colon_flags)
            # Skip any intermediate bytes (0x20..0x2F) preceding the final byte
            # (e.g. the space in DECSCUSR `ESC[1 q`).
            while j < n && 0x20 <= data[j] <= 0x2F
              j += 1
            end
            final = j < n ? data[j] : 0_u8
            case priv ? 0_u8 : final
            when 0x6D # 'm' — SGR
              params = nums.empty? ? [0] : nums
              param_colons = nums.empty? ? [false] : colon_flags
              k = 0
              while k < params.size
                c = params[k]
                case c
                when 0        then fg = nil; bg = nil; fgb = false; bgb = false; rev = false
                when 1        then fgb = true
                when 7        then rev = true  # reverse video: swap fg/bg at raster time
                when 27       then rev = false # reverse off
                when 22       then fgb = false
                when 30..37   then fg = c - 30
                when 90..97   then fg = c - 90; fgb = true
                when 39       then fg = nil
                when 40..47   then bg = c - 40; bgb = false # normal bg clears any prior bright bg
                when 100..107 then bg = c - 100; bgb = true
                when 49       then bg = nil; bgb = false
                when 38, 48
                  # Extended fg/bg selector followed by `5;n` (xterm-256) or
                  # `2;r;g;b` (truecolour). Sub-parameters must be consumed or
                  # they're misread as standalone SGR codes (e.g. a `0` channel
                  # in `48;2;r;0;b` reads as "reset all"). Mapped to the
                  # nearest entry in this decoder's 16-colour palette.
                  idx, consumed = ext_color_index(params, param_colons, k + 1)
                  k += consumed
                  if idx
                    if c == 38
                      fgb = idx >= 8; fg = fgb ? idx - 8 : idx
                    else
                      bgb = idx >= 8; bg = bgb ? idx - 8 : idx
                    end
                  end
                when 58
                  # Underline color (ISO 8613-6): same payload shape as 38/48
                  # but this decoder has no underline-color attribute. Consume
                  # the sub-parameters purely so they aren't misread as
                  # standalone SGR codes (e.g. a `0` channel in `58;2;r;0;b`
                  # would otherwise read as "reset all"); discard the result.
                  _, consumed = ext_color_index(params, param_colons, k + 1)
                  k += consumed
                else # 5 (blink) / 8 (conceal) / … ignored
                end
                k += 1
              end
            when 0x48, 0x66 # 'H' / 'f' — CUP
              y = clampy.call((nums[0]? || 1) - 1)
              x = clampx.call((nums[1]? || 1) - 1)
            when 0x41 then y = clampy.call(y - amt.call(nums[0]?)) # 'A' up
            when 0x42 then y = clampy.call(y + amt.call(nums[0]?)) # 'B' down
            when 0x43 then x = clampx.call(x + amt.call(nums[0]?)) # 'C' right
            when 0x44 then x = clampx.call(x - amt.call(nums[0]?)) # 'D' left
            when 0x4A                                              # 'J' — erase display (2 = whole window)
              if (nums[0]? || 0) == 2
                cells.clear; maxx = 0; maxy = 0; x = 0; y = 0
              end
            when 0x73 then sx = x; sy = y # 's' save cursor
            when 0x75 then x = sx; y = sy # 'u' restore cursor
            else                          # 'K' (erase line) and others: ignored
            end
            i = j + 1
            next
          elsif b == 0x1B
            i += 2 # other escape: skip ESC + next byte
            next
          end

          case b
          when 0x0D then x = 0                               # CR
          when 0x0A then y = clampy.call(y + 1); x = 0       # LF
          when 0x1A then break                               # SUB — DOS EOF marker
          when 0x08 then x = clampx.call(x - 1)              # BS
          when 0x09 then x = clampx.call(((x // 8) + 1) * 8) # TAB
          else
            cells[{x, y}] = {cp437(b), fg, fgb, bg, bgb, rev}
            maxx = x if x > maxx
            maxy = y if y > maxy
            x = clampx.call(x + 1)
            # ANSI.SYS autowrap: once printing advances past the right margin,
            # return to column 0 on the next row. (CUP/CUF motion above does not
            # pass through here, so explicit positioning stays unwrapped.)
            if x >= wrap_width
              x = 0
              y = clampy.call(y + 1)
            end
          end
          i += 1
        end

        cols = {maxx + 1, 1}.max
        rows = {maxy + 1, 1}.max

        # Rasterize a small pixel-block per art cell (not the full 8x16 glyph,
        # since output backends nearest-neighbour-downsample the bitmap and would
        # shred a high-res text image). Each sub-pixel is the glyph's fg/bg
        # blended by the *coverage* (ink fraction) of the glyph region it maps to.
        #
        # Two resolutions, chosen by `media.ansi_art_detail`:
        #   * on (default): 2x4 per cell — enough sub-cell structure for the Glyph
        #     backend (quadrant/sextant/octant/braille) to resolve outlines.
        #   * off: 1x2 per cell — one averaged colour; softer, but cleaner under
        #     the Ansi backend and at 1:1 (nothing to alias).
        #
        # Each sub-pixel column is 1-wide x 2-tall scaled, so after the cell
        # backends' ~2:1 aspect correction, native size is the art's `cols`x`rows`
        # grid — "1:1" is one art cell per terminal cell.
        detail = Crysterm::Config.media_ansi_art_detail
        cw = detail ? 2 : 1
        ch = detail ? 4 : 2
        pw = cols * cw
        ph = rows * ch
        black = PNGGIF::Pixel.new(0, 0, 0)
        bmp = Array(Array(PNGGIF::Pixel)).new(ph) { Array(PNGGIF::Pixel).new(pw, black) }

        # Memoize the decoded glyph per distinct `Char` across all cells, so the
        # `char.to_s` key allocation happens once per glyph, not once per cell.
        glyph_cache = {} of Char => Array(Array(Int32))

        rows.times do |cy|
          cols.times do |cx|
            c = cells[{cx, cy}]?
            char, cfg, cfgb, cbg, cbgb, crev = c || {' ', nil, false, nil, false, false}
            # ANSI.SYS/VGA: SGR 1 (bold) intensifies the current foreground,
            # including the default — `ESC[1m` alone is bright white (15), not
            # light gray (7). So brighten the default fg too, not only explicit ones.
            fg_rgb = pal((cfg || 7) + (cfgb ? 8 : 0))
            bg_rgb = pal(cbg ? (cbgb ? cbg + 8 : cbg) : 0)
            # Reverse video (SGR 7): swap ink/paper. Resolved here (after defaults)
            # so a reversed default cell becomes black-on-white, as on a real VT.
            fg_rgb, bg_rgb = bg_rgb, fg_rgb if crev
            g = glyph_cache[char] ||= font.glyph(char.to_s)
            gw, gh = dims(g)
            ch.times do |dy|
              drow = bmp[cy * ch + dy]
              cw.times do |dx|
                cov = subcoverage(g, gw, gh, dx, cw, dy, ch)
                drow[cx * cw + dx] = blend(fg_rgb, bg_rgb, cov)
              end
            end
          end
        end

        # Round-trip through `encode_png` rather than the frames constructor:
        # the latter leaves `frames` non-nil, which cell backends read as
        # "animated" and then render nothing (no frame loop). A decoded still
        # has `frames == nil`, the single-image path every backend expects.
        PNGGIF::PNG.new(PNGGIF.encode_png(bmp))
      end
    end
  end
end
