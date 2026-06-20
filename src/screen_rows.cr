module Crysterm
  class Screen
    # Screen rows and cells

    # A single screen cell.
    #
    # `Cell` carries no data of its own: it is a lightweight, stack-allocated
    # handle holding a reference to its owning `Row` and its column index. All
    # reads and writes go straight to the row's parallel arrays (`attrs`,
    # `chars`) and the sparse grapheme overlay.
    #
    # This keeps the contiguous-array memory layout (which benchmarks
    # (`benchmarks/cells-vs-arrays.cr`) show to be the fastest way to access the
    # cell grid, ~2.7x faster than a heap-allocated `class Cell`) while
    # preserving the familiar `line[x].attr = ...` mutation API used throughout
    # the rendering and drawing code.
    #
    # Grapheme support (Phase 1): the common case — one codepoint per cell — is
    # still stored directly in `chars : Array(Char)` for speed. A cell that holds
    # a multi-codepoint **grapheme cluster** (e.g. a base + combining mark) keeps
    # its *base* codepoint in `chars` and the full cluster in the row's sparse
    # `graphemes` overlay (allocated lazily, only when needed). A **wide**
    # (2-column) grapheme occupies two cells: the grapheme cell, and a following
    # *continuation* cell (`CONTINUATION` sentinel) that the draw loop must emit
    # nothing for. Legacy (non-`full_unicode`) rendering never creates overlay or
    # continuation cells, so its fast path is unchanged.
    struct Cell
      include Comparable(self)

      # Sentinel stored in `chars` for the trailing cell of a wide grapheme. The
      # draw loop emits nothing for it — the wide glyph already advanced the
      # terminal cursor by two columns. NUL never appears in real content
      # (control chars are stripped by `process_content`).
      CONTINUATION = '\0'

      def initialize(@row : Row, @index : Int32)
      end

      def attr : Int64
        @row.attrs.unsafe_fetch(@index)
      end

      # The cell's primary codepoint: the character itself for a single-codepoint
      # cell, the *base* codepoint of a cluster, or `CONTINUATION` for the
      # trailing cell of a wide grapheme.
      def char : Char
        @row.chars.unsafe_fetch(@index)
      end

      def attr=(value : Int64) : Int64
        @row.attrs.unsafe_put(@index, value)
        value
      end

      # Sets a single codepoint, dropping any grapheme-cluster overlay this cell
      # had. (Cheap on the legacy hot path: when the row has no overlay at all,
      # `delete_grapheme` is just a nil check.)
      def char=(value : Char) : Char
        @row.chars.unsafe_put(@index, value)
        @row.delete_grapheme @index
        value
      end

      # The cell's full grapheme cluster as a `String`: the overlay cluster if
      # present, else the single codepoint (`""` for a continuation cell).
      def grapheme : String
        if g = @row.grapheme_at?(@index)
          g
        else
          c = @row.chars.unsafe_fetch(@index)
          c == CONTINUATION ? "" : c.to_s
        end
      end

      # Stores a grapheme cluster. A single-codepoint value is kept inline in
      # `chars`; a multi-codepoint cluster keeps its base codepoint inline and
      # the whole cluster in the overlay. Marking the trailing cell of a wide
      # grapheme as a continuation is the caller's responsibility
      # (`#continuation!`).
      def grapheme=(value : String) : String
        if value.size <= 1
          @row.chars.unsafe_put(@index, value.empty? ? CONTINUATION : value[0])
          @row.delete_grapheme @index
        else
          @row.chars.unsafe_put(@index, value[0])
          @row.set_grapheme @index, value
        end
        value
      end

      # The overlay cluster for this cell, or `nil` if it holds at most one
      # codepoint. Used for fast, allocation-free equality on the diff path.
      def grapheme_overlay : String?
        @row.grapheme_at?(@index)
      end

      # Whether this is the trailing cell of a wide grapheme (draw emits nothing).
      def continuation? : Bool
        @row.chars.unsafe_fetch(@index) == CONTINUATION
      end

      # Marks this cell as the continuation of the preceding wide grapheme.
      def continuation! : Nil
        @row.chars.unsafe_put(@index, CONTINUATION)
        @row.delete_grapheme @index
      end

      # Display width of this cell in terminal columns (0 for a continuation
      # cell, 1 or 2 otherwise).
      def width : Int32
        ::Crysterm::Unicode.width grapheme
      end

      # Cell-vs-cell equality compares *values* (attr + grapheme), not handle
      # identity, so that cells from different rows (e.g. `@lines` vs `@olines`)
      # can be diffed during drawing.
      #
      # Fast path: compares `attr` and the base `char` first, then the overlay
      # references. For the common single-codepoint cell both overlays are `nil`,
      # so no `String` is allocated.
      def ==(other : Cell)
        attr == other.attr && char == other.char && grapheme_overlay == other.grapheme_overlay
      end

      # Cell-vs-tuple equality compares cell *values* (attr + char). This is what
      # drives the diffing renderer: the unchanged-cell skip in `screen_drawing`
      # (`ox == {desired_attr, desired_char}`), the BCE line-clear (`line[xx] !=
      # {desired_attr, ' '}`), and the `cell != {attr, ch}` write guards in
      # `widget_rendering`/`fill_region`. A cell that holds a multi-codepoint
      # cluster is never equal to a single-char tuple (so such writes are not
      # skipped).
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
          attr == other[0] && char == other[1] && grapheme_overlay.nil?
        {% end %}
      end

      def <=>(other : Cell)
        if (d = attr <=> other.attr) == 0
          if (d2 = char <=> other.char) == 0
            (grapheme_overlay || "") <=> (other.grapheme_overlay || "")
          else
            d2
          end
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
    # Multi-codepoint grapheme clusters are kept in a sparse `@graphemes` overlay
    # (index -> cluster), allocated only when a cluster is actually stored, so
    # rows of plain text carry no extra memory.
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

      # Sparse overlay of multi-codepoint grapheme clusters (cell index ->
      # cluster). Lazily allocated; nil for rows that only hold single codepoints.
      @graphemes : Hash(Int32, String)? = nil

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

      # The overlay grapheme cluster stored at `index`, or nil.
      def grapheme_at?(index : Int) : String?
        @graphemes.try &.[index.to_i32]?
      end

      # Stores a multi-codepoint cluster at `index` (allocating the overlay on
      # first use).
      def set_grapheme(index : Int, value : String) : Nil
        (@graphemes ||= {} of Int32 => String)[index.to_i32] = value
      end

      # Drops any overlay cluster at `index`. Cheap when no overlay exists.
      def delete_grapheme(index : Int) : Nil
        @graphemes.try &.delete(index.to_i32)
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

      # Removes the last cell (and any overlay it carried).
      def pop : Nil
        delete_grapheme(@attrs.size - 1)
        @attrs.pop
        @chars.pop
      end
    end
  end
end
