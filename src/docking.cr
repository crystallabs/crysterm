module Crysterm
  # Docking behavior when borders don't have the same color
  enum DockContrast
    Ignore   # Just render, colors on adjacent cells will be different
    DontDock # Do not perform docking (leave default look)
    Blend    # Blend/mix colors for as smooth a transition as possible
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
  # were emitted (only rows with *horizontal* segments need collecting; vertical
  # segments are picked up when a horizontal stop crosses them), then call
  # `dock` to re-evaluate every relevant cell on those rows. See `Window#_dock`
  # and `Widget#register_dock_stops` for the callers.
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
    # The all-zero pattern (`0000`, no line-drawing neighbor in any direction) is
    # deliberately *absent* rather than mapped to `' '`: `#angle_at` resolves it
    # via `ANGLE_TABLE[angle]? || ch`, so a missing `0` key falls through to the
    # cell's original character. A truthy `' '` entry would instead *erase* an
    # isolated line glyph (e.g. a one-cell `Line`) when docking ran over it.
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
    # each box-drawing glyph is made of. Lets `#angle_at` ask which arms a
    # cell's own glyph draws, so docking can *add* a join without *severing* an
    # arm the cell already extends toward a neighboring line. See the
    # self-preservation pass in `#angle_at`.
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

    # Packed lookup tables over the contiguous U+2500..U+253C span all eleven
    # box-drawing glyphs live in, replacing the per-cell Hash probes and tuple
    # scans (`GLYPH_BITS[ch]?`, `ANGLES.includes?`, the four directional
    # `*_ANGLES.includes?`, `ANGLE_TABLE[...]?`) with array reads + bit tests.
    #
    # `GLYPH_BITS_BY_ORD[ord - 0x2500]` is the glyph's 4-bit stroke pattern
    # (`[L][U][R][D]`, same encoding as `GLYPH_BITS`), `0` for a non-box char —
    # so "is an angle" == "bits != 0", and the directional memberships collapse
    # to arm tests: e.g. `L_ANGLES.includes?(c)` == "c has a RIGHT arm".
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

    # The stroke pattern of `c`'s glyph, or 0 for a non-box-drawing char.
    # Packed-table equivalent of `GLYPH_BITS[c]? || 0`.
    @[AlwaysInline]
    private def glyph_bits(c : Char) : Int32
      o = c.ord
      (0x2500 <= o <= 0x253C) ? GLYPH_BITS_BY_ORD.unsafe_fetch(o - 0x2500).to_i : 0
    end

    # Reusable scratch buffer for the sorted stop rows, mutated and reused by
    # every `#dock` call instead of allocating a fresh array per frame. `#dock`
    # runs once per frame from `Window#_dock` (and on demand from
    # `Widget#dock_rows`); neither nests or runs concurrently (rendering is
    # single-fiber), so one shared buffer is safe. `Array#clear` keeps the
    # backing capacity, so after warmup the per-frame collection allocates nothing.
    @@sorted_stops = [] of Int32

    # Re-evaluates and docks every angle character found on each of the `stops`
    # rows of `lines`. `width` is the number of columns to scan per row, and
    # `dock_contrast` controls how cells with differing colors/attributes are
    # treated (see `DockContrast`).
    def dock(lines, stops, width, dock_contrast : DockContrast)
      # `stops` is a `Hash(Int32, Bool)`; `keys` (and the previous
      # `.map(&.to_i)`) allocated a fresh `Array(Int32)` every frame. Copy keys
      # into the reused scratch buffer and sort in place instead.
      sorted = @@sorted_stops
      sorted.clear
      stops.each_key { |k| sorted << k }
      sorted.sort!.each do |y|
        row = lines[y]?
        next unless row

        # Hoist the row and operate on its backing `chars` array directly,
        # instead of re-indexing `lines[y]` and constructing a fresh `Cell`
        # handle per column. Bound the scan by the row's actual width so the
        # access can be unchecked; `width` is the window width and rows are
        # sized to it, so in practice this still scans every column.
        chars = row.chars
        n = width < chars.size ? width : chars.size
        x = 0
        while x < n
          if angle? chars.unsafe_fetch(x)
            chars.unsafe_put(x, angle_at(lines, row, x, y, dock_contrast))
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
    #
    # Public entry point: resolves the cell's row and delegates to the
    # row-hoisted overload below, which `#dock` calls directly.
    def angle_at(lines, x, y, dock_contrast : DockContrast)
      angle_at lines, lines[y], x, y, dock_contrast
    end

    # :ditto: — *row* is the already-resolved `lines[y]`.
    def angle_at(lines, row, x, y, dock_contrast : DockContrast)
      # Two separate accumulators: `recip` is the arms contributed by neighbors
      # that *reciprocate* (point back at this cell — a real connection), and
      # `preserve` is the cell's own arms that merely sit beside a present line
      # glyph. Must stay distinct (see the guard below).
      recip = 0
      preserve = 0
      # Row is already resolved by the caller; read attr/char from the backing
      # arrays once instead of re-indexing `lines[y]` and building two `Cell`
      # handles.
      attr = row.attrs.unsafe_fetch(x)
      ch = row.chars.unsafe_fetch(x)

      # The arms this cell's own glyph already draws (0 for a non-box char).
      self_bits = glyph_bits ch

      # Evaluate each of the four neighbors (left, up, right, down); `each`
      # over a tuple unrolls at compile time. A `nil` result means `DontDock`
      # hit a contrasting neighbor, in which case we keep the original character.
      # `opp_bit` is the arm a neighbor must draw to point back at this cell
      # (the packed-table form of the old `L_ANGLES`/... membership tuples).
      { {-1, 0, BITWISE_R_ANGLE, BITWISE_L_ANGLE},
       {0, -1, BITWISE_D_ANGLE, BITWISE_U_ANGLE},
       {1, 0, BITWISE_L_ANGLE, BITWISE_R_ANGLE},
       {0, 1, BITWISE_U_ANGLE, BITWISE_D_ANGLE} }.each do |(dx, dy, opp_bit, bit)|
        result = neighbor_angle lines, row, x, y, dx, dy, opp_bit, bit, attr, dock_contrast
        return ch if result.nil?
        recip |= result

        # Preserve this cell's own arm toward any *present* line-drawing
        # neighbor, even one whose glyph doesn't point back. Docking otherwise
        # rebuilds a junction purely from reciprocating neighbors, so where one
        # box's border continues past another's overlapping corner — e.g. a
        # parent menu's right border running past a sub-popup's top-left `┌` one
        # row below — the parent's top-right `┐` finds no down-reciprocation and
        # is reduced to `─`, dropping the corner. Keeping the arm where a real
        # line sits below/beside it lets docking add joins without severing an
        # existing corner. Still gated on a line neighbor, so a `┐` against a
        # blank/off-grid edge reduces as before.
        if (self_bits & bit) != 0 && neighbor_line?(lines, x, y, dx, dy)
          preserve |= bit
        end
      end

      # No neighbor reciprocates: nothing actually connects to this cell, so keep
      # its own glyph rather than letting self-preservation be the *sole* content
      # of the angle. Self-preservation augments a real junction, never stands
      # alone — a lone preserved arm maps to a straight stroke, severing the very
      # corner it exists to protect. Without this guard a `┌` with a `─` directly
      # below it (which doesn't reciprocate) resolved to `│`, dropping the
      # corner; likewise `└`/`┐`/`┘` against a single perpendicular rule. This
      # also subsumes the isolated-glyph rule (no neighbors → `recip == 0`).
      return ch if recip == 0

      # `recip | preserve` only ever carries the four arm bits, so it indexes
      # the 16-entry table directly; `'\0'` (the absent `0` entry) keeps `ch`.
      a = ANGLE_BY_BITS.unsafe_fetch(recip | preserve)
      a == '\0' ? ch : a
    end

    # Whether `c` is one of the box-drawing glyphs in `ANGLES`. All eleven live
    # in the contiguous U+2500..U+253C span, so a range pre-check cheaply rejects
    # the typically many blank/non-box cells before the tuple membership test.
    # Identical result to `ANGLES.includes?(c)` (every `ANGLES` glyph has a
    # non-zero stroke pattern), via one packed-table read.
    @[AlwaysInline]
    private def angle?(c : Char) : Bool
      o = c.ord
      0x2500 <= o <= 0x253C && GLYPH_BITS_BY_ORD.unsafe_fetch(o - 0x2500) != 0
    end

    # Resolves the neighbor cell offset by (`dx`, `dy`) from (`x`, `y`) to its
    # `{row, column}`, or nil when it falls off the grid. The explicit `>= 0`
    # guards matter: Crystal's `[]?` treats negative indices as counting from
    # the end, so without them a left/up lookup at the grid edge would wrap
    # around instead of being absent.
    @[AlwaysInline]
    private def neighbor_cell(lines, x, y, dx, dy)
      nx, ny = x + dx, y + dy
      return nil unless nx >= 0 && ny >= 0
      nrow = lines[ny]?
      return nil unless nrow && nx < nrow.size
      {nrow, nx}
    end

    # Whether the cell offset by (`dx`, `dy`) from (`x`, `y`) holds a
    # line-drawing glyph.
    private def neighbor_line?(lines, x, y, dx, dy) : Bool
      return false unless cell = neighbor_cell(lines, x, y, dx, dy)
      nrow, nx = cell
      angle? nrow.chars.unsafe_fetch(nx)
    end

    # Evaluates a single neighbor of the cell at (`x`, `y`), offset by
    # (`dx`, `dy`). Returns `bit` if that neighbor holds a line-drawing
    # character pointing back at this cell (drawing the `opp_bit` arm — the
    # packed-table form of the old `angles` membership tuple), `0` if it does
    # not participate, or `nil` to
    # signal the caller to abort docking (`DontDock` with a contrasting
    # neighbor). For `Blend`, the cell's attribute is blended with the
    # neighbor's as a side effect.
    private def neighbor_angle(lines, row, x, y, dx, dy, opp_bit, bit, attr, dock_contrast)
      return 0 unless cell = neighbor_cell(lines, x, y, dx, dy)
      nrow, nx = cell

      return 0 unless (glyph_bits(nrow.chars.unsafe_fetch(nx)) & opp_bit) != 0

      nattr = nrow.attrs.unsafe_fetch(nx)
      if nattr != attr
        case dock_contrast
        when DockContrast::DontDock
          return nil
        when DockContrast::Blend
          # Blend into the cell's *current* attr (`row.attrs[x]`), not the
          # captured original `attr`: `#angle_at` evaluates all four neighbors,
          # and a `┼`/`├`/… junction can border more than one contrasting color.
          # Blending against the original each time made every contrasting
          # neighbor overwrite the previous one, losing all but the last. The
          # contrast test above still compares against the original `attr`, so
          # which neighbors count as contrasting is unchanged.
          row.attrs.unsafe_put(x, Colors.blend(nattr, row.attrs.unsafe_fetch(x)))
          # when DockContrast::Ignore
          #  Note: ::Ignore needs no custom handler/code; it works as-is.
        end
      end

      bit
    end
  end
end
