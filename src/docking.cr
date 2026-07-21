module Crysterm
  # Docking behavior when borders don't have the same color
  enum DockContrast
    Ignore # Just render, colors on adjacent cells will be different
    Skip   # Do not perform docking (leave default look)
    Blend  # Blend/mix colors for as smooth a transition as possible
  end

  # Reusable "docking" component.
  #
  # Docking takes points where line-drawing characters cross or meet (e.g. two
  # box borders touching, or `Widget::Line`s crossing) and replaces the
  # overlapping/adjacent characters with a single character that joins them
  # seamlessly. For example, these border-overlapped elements:
  #
  #     ┌─────────┌─────────┐
  #     │ box1    │ box2    │
  #     └─────────└─────────┘
  #
  # become:
  #
  #     ┌─────────┬─────────┐
  #     │ box1    │ box2    │
  #     └─────────┴─────────┘
  #
  # The component is agnostic about *what* produced the characters: it operates
  # purely on the in-memory grid of cells (`lines`), so the same logic serves
  # borders, `Line` widgets, and anything else drawing with the box-drawing
  # characters in `ANGLES`.
  #
  # Callers collect the set of rows ("stops") on which line-drawing characters
  # were emitted — only rows with *horizontal* segments need collecting, since
  # vertical segments are picked up when a horizontal stop crosses them — then
  # call `dock` to re-evaluate every relevant cell on those rows.
  module Docking
    extend self

    # Collection of helper chars for drawing borders and their angles.

    # Left, top, right, and bottom angles
    L_ANGLES = {'┌', '└', '┼', '├', '┴', '┬', '─'}
    U_ANGLES = {'┐', '┌', '┼', '├', '┤', '┬', '│'}
    R_ANGLES = {'┘', '┐', '┼', '┤', '┴', '┬', '─'}
    D_ANGLES = {'┘', '└', '┼', '├', '┤', '┴', '│'}

    # All angles, uniq list
    ANGLES = {'┘', '┐', '┌', '└', '┼', '├', '┤', '┴', '┬', '│', '─'}

    # Every ACS angle character can be represented by 4 bits ordered like this:
    # [langle][uangle][rangle][dangle]
    #
    # The all-zero pattern (no line-drawing neighbor in any direction) is
    # deliberately absent, so a lookup misses and the caller keeps the cell's
    # own character; a `' '` entry here would erase an isolated line glyph.
    ANGLE_TABLE = {
       1 => '│', # ?   '0001'
       2 => '─', # ??  '0010'
       3 => '┌', #     '0011'
       4 => '│', # ?   '0100'
       5 => '│', #     '0101'
       6 => '└', #     '0110'
       7 => '├', #     '0111'
       8 => '─', # ??  '1000'
       9 => '┐', #     '1001'
      10 => '─', # ??  '1010'
      11 => '┬', #     '1011'
      12 => '┘', #     '1100'
      13 => '┤', #     '1101'
      14 => '┴', #     '1110'
      15 => '┼', #     '1111'
    }

    BITWISE_L_ANGLE = 1 << 3
    BITWISE_U_ANGLE = 1 << 2
    BITWISE_R_ANGLE = 1 << 1
    BITWISE_D_ANGLE = 1 << 0

    # The inverse of `ANGLE_TABLE`: the 4-bit stroke pattern (`[L][U][R][D]`)
    # each box-drawing glyph is made of. Lets docking ask which arms a cell's
    # own glyph draws, so it can *add* a join without *severing* an arm the cell
    # already extends toward a neighboring line.
    GLYPH_BITS = {
      '│' => BITWISE_U_ANGLE | BITWISE_D_ANGLE,
      '─' => BITWISE_L_ANGLE | BITWISE_R_ANGLE,
      '┌' => BITWISE_R_ANGLE | BITWISE_D_ANGLE,
      '┐' => BITWISE_L_ANGLE | BITWISE_D_ANGLE,
      '└' => BITWISE_U_ANGLE | BITWISE_R_ANGLE,
      '┘' => BITWISE_L_ANGLE | BITWISE_U_ANGLE,
      '├' => BITWISE_U_ANGLE | BITWISE_R_ANGLE | BITWISE_D_ANGLE,
      '┤' => BITWISE_L_ANGLE | BITWISE_U_ANGLE | BITWISE_D_ANGLE,
      '┬' => BITWISE_L_ANGLE | BITWISE_R_ANGLE | BITWISE_D_ANGLE,
      '┴' => BITWISE_L_ANGLE | BITWISE_U_ANGLE | BITWISE_R_ANGLE,
      '┼' => BITWISE_L_ANGLE | BITWISE_U_ANGLE | BITWISE_R_ANGLE | BITWISE_D_ANGLE,
    }

    # `GLYPH_BITS` as a flat array over the contiguous U+2500..U+253C span all
    # eleven box-drawing glyphs live in, so the per-cell probes are array reads
    # and bit tests rather than Hash/tuple scans. An entry is the glyph's 4-bit
    # stroke pattern, `0` for a non-box char — so "is an angle" == "bits != 0",
    # and the directional memberships collapse to arm tests
    # (`L_ANGLES.includes?(c)` == "c has a RIGHT arm").
    GLYPH_BITS_BY_ORD = begin
      arr = StaticArray(UInt8, 0x3D).new(0_u8)
      GLYPH_BITS.each { |ch, bits| arr[ch.ord - 0x2500] = bits.to_u8 }
      arr
    end

    # `ANGLE_TABLE` as a flat array; `'\0'` marks the absent `0` entry (no
    # reciprocating neighbor — caller keeps the original char).
    ANGLE_BY_BITS = begin
      arr = StaticArray(Char, 16).new('\0')
      ANGLE_TABLE.each { |k, v| arr[k] = v }
      arr
    end

    # Stroke patterns of the arc (rounded) corners `╭ ╮ ╯ ╰` — the contiguous
    # U+256D..U+2570 span. Each carries the same arms as its square counterpart
    # (`┌ ┐ ┘ └`), so a rounded border participates in junction merging: an
    # abutting line turns the arc into the square junction (Unicode has no
    # rounded tees), while a non-merging arc keeps its arc.
    ARC_BITS_BY_ORD = StaticArray[
      (BITWISE_R_ANGLE | BITWISE_D_ANGLE).to_u8, # ╭ U+256D
      (BITWISE_L_ANGLE | BITWISE_D_ANGLE).to_u8, # ╮ U+256E
      (BITWISE_L_ANGLE | BITWISE_U_ANGLE).to_u8, # ╯ U+256F
      (BITWISE_U_ANGLE | BITWISE_R_ANGLE).to_u8, # ╰ U+2570
    ]

    # The stroke pattern of `c`'s glyph, or 0 for a non-box-drawing char. With
    # *ascii*, the ASCII line/junction chars participate too: `-`/`|` as
    # straight runs, `+` as a full four-arm junction. Those chars are hardcoded
    # here, so a `Glyphs.set` override of the corresponding ascii-tier roles
    # isn't honored.
    @[AlwaysInline]
    private def glyph_bits(c : Char, ascii : Bool = false) : Int32
      o = c.ord
      return GLYPH_BITS_BY_ORD.unsafe_fetch(o - 0x2500).to_i if 0x2500 <= o <= 0x253C
      return ARC_BITS_BY_ORD.unsafe_fetch(o - 0x256D).to_i if 0x256D <= o <= 0x2570
      if ascii
        case c
        when '|' then return BITWISE_U_ANGLE | BITWISE_D_ANGLE
        when '-' then return BITWISE_L_ANGLE | BITWISE_R_ANGLE
        when '+' then return BITWISE_L_ANGLE | BITWISE_U_ANGLE | BITWISE_R_ANGLE | BITWISE_D_ANGLE
        end
      end
      0
    end

    # The ASCII rendition of a 4-bit junction pattern: straight runs keep
    # their line char, anything with a corner or crossing is `+`.
    @[AlwaysInline]
    private def ascii_angle(bits : Int32) : Char
      case bits
      when BITWISE_U_ANGLE, BITWISE_D_ANGLE, BITWISE_U_ANGLE | BITWISE_D_ANGLE
        '|'
      when BITWISE_L_ANGLE, BITWISE_R_ANGLE, BITWISE_L_ANGLE | BITWISE_R_ANGLE
        '-'
      else
        '+'
      end
    end

    # Reusable scratch buffer for the sorted stop rows, so a frame's collection
    # allocates nothing. Shared: `#dock` must never nest nor run concurrently
    # (rendering is single-fiber).
    @@sorted_stops = [] of Int32

    # Re-evaluates and docks every angle character found on each of the `stops`
    # rows of `lines`. `width` is the number of columns to scan per row, and
    # `dock_contrast` controls how cells with differing colors/attributes are
    # treated (see `DockContrast`). With *ascii* the ASCII line chars `+`/`-`/`|`
    # are merged too, and every junction resolves to its ASCII rendition.
    def dock(lines, stops, width, dock_contrast : DockContrast, *, ascii : Bool = false)
      sorted = @@sorted_stops
      sorted.clear
      # Skip negative stop rows: `lines[y]?` treats a negative index as counting
      # from the END of the array, so an off-top stop would resolve to and
      # corrupt an unrelated row near the bottom of the screen.
      stops.each_key { |k| sorted << k if k >= 0 }
      sorted.sort!.each do |y|
        row = lines[y]?
        next unless row

        # Operate on the backing `chars` array directly, rather than building a
        # `Cell` handle per column. Bound the scan by the row's actual width so
        # the accesses can be unchecked.
        chars = row.chars
        n = width < chars.size ? width : chars.size
        x = 0
        while x < n
          if angle? chars.unsafe_fetch(x), ascii
            chars.unsafe_put(x, angle_at(lines, row, x, y, dock_contrast, ascii: ascii))
            # Mirror `Cell#char=`, which drops any cluster overlay on the cell.
            row.delete_grapheme x
            row.mark_dirty x
          end
          x += 1
        end
      end
    end

    # Returns the appropriate joining/angle character for the cell at (`x`, `y`)
    # in `lines`, based on which of its four neighbors also hold line-drawing
    # characters. `dock_contrast` decides what happens when a neighbor's
    # attribute differs from this cell's.
    def angle_at(lines, x, y, dock_contrast : DockContrast, *, ascii : Bool = false)
      angle_at lines, lines[y], x, y, dock_contrast, ascii: ascii
    end

    # :ditto: — *row* is the already-resolved `lines[y]`.
    def angle_at(lines, row, x, y, dock_contrast : DockContrast, *, ascii : Bool = false)
      # Two separate accumulators: `recip` is the arms contributed by neighbors
      # that *reciprocate* (point back at this cell — a real connection), and
      # `preserve` is the cell's own arms that merely sit beside a present line
      # glyph. Must stay distinct (see the guard below).
      recip = 0
      preserve = 0
      attr = row.attrs.unsafe_fetch(x)
      ch = row.chars.unsafe_fetch(x)

      # The arms this cell's own glyph already draws (0 for a non-box char).
      self_bits = glyph_bits ch, ascii

      # Evaluate each of the four neighbors (left, up, right, down); `each`
      # over a tuple unrolls at compile time. A `nil` result means `Skip`
      # hit a contrasting neighbor, in which case we keep the original character.
      # `opp_bit` is the arm a neighbor must draw to point back at this cell.
      { {-1, 0, BITWISE_R_ANGLE, BITWISE_L_ANGLE},
       {0, -1, BITWISE_D_ANGLE, BITWISE_U_ANGLE},
       {1, 0, BITWISE_L_ANGLE, BITWISE_R_ANGLE},
       {0, 1, BITWISE_U_ANGLE, BITWISE_D_ANGLE} }.each do |(dx, dy, opp_bit, bit)|
        result = neighbor_angle lines, row, x, y, dx, dy, opp_bit, bit, attr, dock_contrast, ascii
        return ch if result.nil?
        recip |= result

        # Preserve this cell's own arm toward any *present* line-drawing
        # neighbor, even one whose glyph doesn't point back — a junction rebuilt
        # purely from reciprocating neighbors severs a corner wherever one box's
        # border runs past another's. Gated on a line neighbor, so a `┐` against
        # a blank/off-grid edge still reduces.
        if (self_bits & bit) != 0 && neighbor_line?(lines, x, y, dx, dy, ascii)
          preserve |= bit
        end
      end

      # Nothing connects to this cell, so keep its own glyph: self-preservation
      # augments a real junction and must never be the sole content of the
      # angle, since a lone preserved arm maps to a straight stroke and severs
      # the very corner it exists to protect. Subsumes the isolated-glyph rule.
      return ch if recip == 0

      # In *ascii* mode, don't reduce a full four-arm `+` when only a single
      # neighbor reciprocates: a plain-text `+` beside another `+`/`-`/`|` on a
      # stop row (e.g. "C++" sharing a row with an ASCII border) would otherwise
      # be rewritten to `-`/`|`. Real ASCII border junctions reciprocate on >= 2
      # arms and still merge.
      return ch if ascii && (recip & (recip - 1)) == 0 &&
                   self_bits == (BITWISE_L_ANGLE | BITWISE_U_ANGLE | BITWISE_R_ANGLE | BITWISE_D_ANGLE)

      # `recip | preserve` only ever carries the four arm bits, so it indexes
      # the 16-entry table directly; `'\0'` (the absent `0` entry) keeps `ch`.
      bits = recip | preserve
      # Identity: the neighbors call for exactly what this cell's glyph already
      # draws. A no-op for the square family, but it lets an arc corner survive
      # its own border's docking pass (`╭`'s pattern indexes to `┌`, which would
      # square a standalone rounded box). A *merging* arc gains an arm, misses
      # this guard, and resolves to the square junction below.
      return ch if bits == self_bits
      a = ANGLE_BY_BITS.unsafe_fetch(bits)
      return ch if a == '\0'
      ascii ? ascii_angle(bits) : a
    end

    # Whether `c` is one of the box-drawing glyphs in `ANGLES` (equivalently:
    # has a non-zero stroke pattern), or an arc corner. The range pre-check
    # cheaply rejects the typically many blank/non-box cells.
    @[AlwaysInline]
    private def angle?(c : Char, ascii : Bool = false) : Bool
      o = c.ord
      return true if 0x2500 <= o <= 0x253C && GLYPH_BITS_BY_ORD.unsafe_fetch(o - 0x2500) != 0
      return true if 0x256D <= o <= 0x2570 # arc corners
      ascii && (c == '+' || c == '-' || c == '|')
    end

    # Resolves the neighbor cell offset by (`dx`, `dy`) from (`x`, `y`) to its
    # `{row, column}`, or nil when it falls off the grid. The explicit `>= 0`
    # guards matter: Crystal's `[]?` treats negative indices as counting from
    # the end, so without them a left/up lookup at the grid edge would wrap
    # around instead of being absent.
    @[AlwaysInline]
    private def neighbor_cell(lines, x, y, dx, dy)
      nx, ny = x + dx, y + dy
      return unless nx >= 0 && ny >= 0
      nrow = lines[ny]?
      return unless nrow && nx < nrow.size
      {nrow, nx}
    end

    # Whether the cell offset by (`dx`, `dy`) from (`x`, `y`) holds a
    # line-drawing glyph.
    private def neighbor_line?(lines, x, y, dx, dy, ascii : Bool = false) : Bool
      return false unless cell = neighbor_cell(lines, x, y, dx, dy)
      nrow, nx = cell
      angle? nrow.chars.unsafe_fetch(nx), ascii
    end

    # Evaluates a single neighbor of the cell at (`x`, `y`), offset by
    # (`dx`, `dy`). Returns `bit` if that neighbor holds a line-drawing
    # character pointing back at this cell (drawing the `opp_bit` arm), `0` if
    # it does not participate, or `nil` to signal the caller to abort docking
    # (`Skip` with a contrasting neighbor). For `Blend`, the cell's
    # attribute is blended with the neighbor's as a side effect.
    private def neighbor_angle(lines, row, x, y, dx, dy, opp_bit, bit, attr, dock_contrast, ascii : Bool = false)
      return 0 unless cell = neighbor_cell(lines, x, y, dx, dy)
      nrow, nx = cell

      return 0 unless (glyph_bits(nrow.chars.unsafe_fetch(nx), ascii) & opp_bit) != 0

      nattr = nrow.attrs.unsafe_fetch(nx)
      if nattr != attr
        case dock_contrast
        when DockContrast::Skip
          return
        when DockContrast::Blend
          # Blend into the cell's *current* attr, not the captured original: a
          # junction can border more than one contrasting color, and each must
          # accumulate rather than overwrite the last. (The contrast test above
          # still compares against the original, so which neighbors count as
          # contrasting is unaffected.)
          #
          # Only the COLORS are blended: `Colors.blend` returns its first
          # argument's flags, which would transplant the neighbor's
          # reverse/bold/underline onto the junction cell. Repack with the
          # cell's own flags.
          cur = row.attrs.unsafe_fetch(x)
          blended = Colors.blend(nattr, cur)
          row.attrs.unsafe_put(x, Attr.pack(Attr.flags(cur), Attr.fg(blended), Attr.bg(blended)))
          # when DockContrast::Ignore
          #  Note: ::Ignore needs no custom handler/code; it works as-is.
        end
      end

      bit
    end
  end
end
