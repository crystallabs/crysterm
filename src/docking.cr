module Crysterm
  # Docking behavior when borders don't have the same color
  enum DockContrast
    Ignore   # Just render, colors on adjacent cells will be different
    DontDock # Do not perform docking (leave default look)
    Blend    # Blend/mix colors for as smooth a transition as possible
  end

  # Reusable "docking" component.
  #
  # Docking takes the points where line-drawing characters cross or meet
  # (e.g. two box borders touching, or `Widget::Line`s crossing) and replaces
  # the overlapping/adjacent characters with a single character that joins them
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
  # The component is intentionally agnostic about *what* produced the
  # characters. It operates purely on the in-memory grid of cells (`lines`),
  # so the same logic serves borders, `Line` widgets, and anything else that
  # draws with the box-drawing characters in `ANGLES`.
  #
  # Callers collect the set of rows ("stops") on which line-drawing characters
  # were emitted (only rows with *horizontal* segments need to be collected;
  # vertical segments are picked up when a horizontal stop crosses them), then
  # call `dock` to re-evaluate every relevant cell on those rows. See
  # `Screen#_dock` and `Widget#register_dock_stops` for the callers.
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

    # Every ACS angle character can be
    # represented by 4 bits ordered like this:
    # [langle][uangle][rangle][dangle]
    #
    # The all-zero pattern (`0000`, no line-drawing neighbor in any direction) is
    # deliberately *absent* rather than mapped to `' '`: `#angle_at` resolves it
    # via `ANGLE_TABLE[angle]? || ch`, so a missing `0` key falls through to the
    # cell's original character. This mirrors blessed, whose `angleTable['0000']`
    # is the empty (falsy) string and thus `angleTable[angle] || ch` keeps the
    # original glyph. A truthy `' '` entry instead *erased* an isolated line
    # glyph (e.g. a one-cell `Line`, or a rule whose neighbors were cleared) when
    # docking ran over it.
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
    # each box-drawing glyph is itself made of. Lets `#angle_at` ask which arms a
    # cell's OWN glyph draws, so docking can *add* a join without ever *severing*
    # an arm the cell already extends toward a neighboring line. See the
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

    # Re-evaluates and docks every angle character found on each of the `stops`
    # rows of `lines`. `width` is the number of columns to scan per row, and
    # `dock_contrast` controls how cells with differing colors/attributes are
    # treated (see `DockContrast`).
    def dock(lines, stops, width, dock_contrast : DockContrast)
      # `stops` is a `Hash(Int32, Bool)`, so `keys` is already `Array(Int32)`:
      # the previous `.map(&.to_i)` allocated a second identical array each
      # frame. `keys` returns a fresh array, so sort it in place.
      stops.keys.sort!.each do |y|
        row = lines[y]?
        next unless row

        # Hoist the row and operate on its backing `chars` array directly,
        # instead of re-indexing `lines[y]` and constructing a fresh `Cell`
        # handle for every column (the row is fixed for the whole scan). Bound
        # the scan by the row's actual width so the access can be unchecked;
        # `width` is the screen width and rows are sized to it, so in practice
        # this still scans every column.
        chars = row.chars
        n = width < chars.size ? width : chars.size
        x = 0
        while x < n
          if ANGLES.includes? chars.unsafe_fetch(x)
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
    # Public entry point (original signature): resolves the cell's row and
    # delegates to the row-hoisted overload below. `#dock` calls that overload
    # directly with the row it already has.
    def angle_at(lines, x, y, dock_contrast : DockContrast)
      angle_at lines, lines[y], x, y, dock_contrast
    end

    # :ditto: — *row* is the already-resolved `lines[y]`.
    def angle_at(lines, row, x, y, dock_contrast : DockContrast)
      # Two separate accumulators: `recip` is the arms contributed by neighbors
      # that *reciprocate* (point back at this cell — a real connection), and
      # `preserve` is the cell's OWN arms that merely sit beside a present line
      # glyph. They must stay distinct (see the guard below).
      recip = 0
      preserve = 0
      # The center cell's row is already resolved by the caller; read its attr
      # and char from the backing arrays once instead of re-indexing `lines[y]`
      # and building two `Cell` handles.
      attr = row.attrs.unsafe_fetch(x)
      ch = row.chars.unsafe_fetch(x)

      # The arms this cell's OWN glyph already draws (0 for a non-box char).
      self_bits = GLYPH_BITS[ch]? || 0

      # Evaluate each of the four neighbors (left, up, right, down). The deltas
      # double as the per-direction angle sets and bits. `each` over a tuple is
      # unrolled at compile time, so this is as cheap as the four inline blocks
      # it replaces. A `nil` result means `DontDock` hit a contrasting neighbor,
      # in which case we keep the original character.
      { {-1, 0, L_ANGLES, BITWISE_L_ANGLE},
       {0, -1, U_ANGLES, BITWISE_U_ANGLE},
       {1, 0, R_ANGLES, BITWISE_R_ANGLE},
       {0, 1, D_ANGLES, BITWISE_D_ANGLE} }.each do |(dx, dy, angles, bit)|
        result = neighbor_angle lines, row, x, y, dx, dy, angles, bit, attr, dock_contrast
        return ch if result.nil?
        recip |= result

        # Preserve this cell's own arm toward any *present* line-drawing
        # neighbor, even one whose glyph doesn't point back. Docking otherwise
        # rebuilds a junction purely from neighbors that "reciprocate", so where
        # one box's border continues past another box's overlapping corner — e.g.
        # a parent menu's right border running past a sub-popup's top-left `┌`
        # one row below — the parent's top-right `┐` finds no down-reciprocation
        # and is reduced to `─`, dropping the corner. Keeping the arm where a
        # real line sits below/beside it lets docking ADD joins without SEVERING
        # an existing corner. Still gated on a line neighbor, so a `┐` against a
        # blank/off-grid edge still reduces exactly as before.
        if (self_bits & bit) != 0 && neighbor_line?(lines, x, y, dx, dy)
          preserve |= bit
        end
      end

      # No neighbor reciprocates: nothing actually connects to this cell, so keep
      # its own glyph rather than letting self-preservation be the *sole* content
      # of the angle. Self-preservation is meant to AUGMENT a real junction, never
      # to stand alone — and a lone preserved arm maps to a straight stroke,
      # severing the very corner the preservation exists to protect. Without this
      # guard a `┌` with a `─` sitting directly below it (the `─` does not open
      # upward, so it does not reciprocate) resolved to `│`, dropping the corner;
      # likewise `└`/`┐`/`┘` against a single perpendicular rule. This subsumes
      # the isolated-glyph rule (no neighbors at all → `recip == 0` → keep `ch`).
      return ch if recip == 0

      ANGLE_TABLE[(recip | preserve)]? || ch
    end

    # Resolves the neighbor cell offset by (`dx`, `dy`) from (`x`, `y`) to its
    # `{row, column}`, or nil when it falls off the grid — the edge-guarded
    # lookup `#neighbor_line?` and `#neighbor_angle` both need. The explicit
    # `>= 0` guards matter: Crystal's `[]?` treats negative indices as counting
    # from the end, so without them a left/up lookup at the grid edge would wrap
    # around to the far side instead of being absent. Inlined so the per-cell
    # docking scan keeps its original codegen.
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
      ANGLES.includes? nrow.chars.unsafe_fetch(nx)
    end

    # Evaluates a single neighbor of the cell at (`x`, `y`), offset by
    # (`dx`, `dy`). Returns `bit` if that neighbor holds a line-drawing
    # character from `angles` (so the angle should include this direction), `0`
    # if it does not participate, or `nil` to signal the caller to abort docking
    # (`DontDock` with a contrasting neighbor). For `Blend`, the cell's
    # attribute is blended with the neighbor's as a side effect.
    private def neighbor_angle(lines, row, x, y, dx, dy, angles, bit, attr, dock_contrast)
      # Resolve the neighbor cell once (edge-guarded) and read its char/attr
      # straight from the backing arrays, rather than indexing `lines[ny][nx]`
      # several times.
      return 0 unless cell = neighbor_cell(lines, x, y, dx, dy)
      nrow, nx = cell

      return 0 unless angles.includes? nrow.chars.unsafe_fetch(nx)

      nattr = nrow.attrs.unsafe_fetch(nx)
      if nattr != attr
        case dock_contrast
        when DockContrast::DontDock
          return nil
        when DockContrast::Blend
          # Blend the center cell toward the neighbor's attr (writes the center
          # row's backing array directly — same cell `lines[y][x]` as before).
          # Blend into the cell's *current* attr (`row.attrs[x]`), not the
          # captured original `attr`: `#angle_at` evaluates all four neighbors in
          # turn, and a `┼`/`├`/… junction can border more than one contrasting
          # color. Blending against the original each time made every contrasting
          # neighbor overwrite the previous one, so only the *last* one processed
          # (down, in the L/U/R/D order) survived and the others' colors were lost
          # — defeating Blend's "as smooth a transition as possible" intent.
          # Accumulating into the running attr mixes in every contrasting
          # neighbor. The contrast test above still compares against the original
          # `attr`, so which neighbors count as contrasting is unchanged (a
          # neighbor matching the cell's true color never triggers a blend).
          row.attrs.unsafe_put(x, Colors.blend(nattr, row.attrs.unsafe_fetch(x)))
          # when DockContrast::Ignore
          #  Note: ::Ignore needs no custom handler/code; it works as-is.
        end
      end

      bit
    end
  end
end
