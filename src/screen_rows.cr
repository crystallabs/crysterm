module Crysterm
  class Screen
    # Screen rows and cells

    # A single screen cell.
    #
    # `Cell` carries no data of its own: it is a lightweight, stack-allocated
    # handle holding a reference to its owning `Row` and its column index. All
    # reads and writes go straight to the row's two parallel arrays (`attrs`
    # and `chars`).
    #
    # This keeps the contiguous-array memory layout (which benchmarks
    # (`benchmarks/cells-vs-arrays.cr`) show to be the fastest way to access the
    # cell grid, ~2.7x faster than a heap-allocated `class Cell`) while
    # preserving the familiar `line[x].attr = ...` mutation API used throughout
    # the rendering and drawing code.
    #
    # Because the handle holds the row (a reference) and an index rather than a
    # copy of the data, mutating through a `Cell` obtained from `row[x]` writes
    # back into the row, exactly as the previous reference-typed cell did.
    struct Cell
      include Comparable(self)

      def initialize(@row : Row, @index : Int32)
      end

      def attr : Int64
        @row.attrs.unsafe_fetch(@index)
      end

      def char : Char
        @row.chars.unsafe_fetch(@index)
      end

      def attr=(value : Int64) : Int64
        @row.attrs.unsafe_put(@index, value)
        value
      end

      def char=(value : Char) : Char
        @row.chars.unsafe_put(@index, value)
        value
      end

      # Cell-vs-cell equality compares *values* (attr + char), not handle
      # identity, so that cells from different rows (e.g. `@lines` vs
      # `@olines`) can be diffed during drawing. This matches the previous
      # `class Cell`, where `Comparable(self)#==` provided value equality.
      def ==(other : Cell)
        attr == other.attr && char == other.char
      end

      # Cell-vs-tuple equality compares cell *values* (attr + char). This is
      # what drives the diffing renderer: the unchanged-cell skip in
      # `screen_drawing` (`ox == {desired_attr, desired_char}`), the BCE
      # line-clear (`line[xx] != {desired_attr, ' '}`), and the `cell != {attr,
      # ch}` write guards in `widget_rendering`/`fill_region`. With a correct
      # value comparison those branches do real work, so the draw loop only
      # emits the cells that actually changed since the previous frame
      # (`@olines`) instead of repainting the whole screen every frame.
      #
      # HISTORY: the previous `class Cell` inadvertently disabled all of this.
      # `cell == {attr, char}` did not use the defined `<=>(Tuple)` — Comparable
      # only provides `==` for another Cell, so the call fell through to
      # `Reference#==(other)`, the catch-all that returns false. The comparison
      # was therefore constant-false (and `!=` constant-true), which forced a
      # full-screen repaint each frame even though `screen_rendering`'s reset
      # logic was written assuming this diffing works.
      #
      # The `legacy_cell_eq` compile flag restores that constant-false behavior
      # for A/B testing/benchmarking against the old full-repaint path.
      def ==(other : Tuple(Int64, Char))
        {% if flag?(:legacy_cell_eq) %}
          false
        {% else %}
          attr == other[0] && char == other[1]
        {% end %}
      end

      def <=>(other : Cell)
        if (d = attr <=> other.attr) == 0
          char <=> other.char
        else
          d
        end
      end

      def <=>(other : Tuple(Int64, Char))
        if (d = attr <=> other[0]) == 0
          char <=> other[1]
        else
          d
        end
      end
    end

    # A single screen row.
    #
    # Storage is two parallel arrays (`attrs` of `Int64`, `chars` of `Char`)
    # rather than an array of cell objects, which gives a contiguous,
    # cache-friendly layout for the per-cell scans in rendering and drawing.
    # `Indexable(Cell)` provides `[]`, `[]?`, `each`, etc.; indexing returns a
    # `Cell` handle into this row.
    #
    # NOTE: this used to subclass `Array(Cell)`. Subclassing a stdlib generic is
    # deprecated and, more importantly, promotes every `Array(Cell)` in the
    # whole program (including in unrelated shards) to the virtual type
    # `Array(Cell)+`, which produces confusing compile errors far away from here
    # (issue #30). Backing the row with plain `Array`s and *including*
    # `Indexable(Cell)` (rather than subclassing `Array`) avoids that entirely.
    class Row
      include Indexable(Cell)

      property dirty = false

      getter attrs : Array(Int64)
      getter chars : Array(Char)

      def initialize
        @attrs = Array(Int64).new
        @chars = Array(Char).new
      end

      # Reserves capacity for `initial_capacity` cells but creates an empty
      # (size 0) row. NOTE: this matches the previous `Row < Array(Cell)`
      # behavior, where `Row.new(width, cell)` delegated to
      # `Array(Cell).new(capacity)` and the cell argument was ignored.
      def initialize(initial_capacity : Int, cell = nil)
        @attrs = Array(Int64).new initial_capacity
        @chars = Array(Char).new initial_capacity
      end

      def size
        @attrs.size
      end

      def unsafe_fetch(index : Int) : Cell
        Cell.new self, index.to_i32
      end

      # Appends a default (empty) cell.
      def push : Nil
        @attrs.push DEFAULT_ATTR
        @chars.push DEFAULT_CHAR
      end

      # Appends a cell with the given attr/char.
      def push(attr : Int64, char : Char) : Nil
        @attrs.push attr
        @chars.push char
      end

      # Removes the last cell.
      def pop : Nil
        @attrs.pop
        @chars.pop
      end
    end
  end
end
