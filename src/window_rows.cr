module Crysterm
  class Window
    # Window rows and cells

    # A single screen cell.
    #
    # `Cell` carries no data of its own: it is a lightweight, stack-allocated
    # handle holding a reference to its owning `Row` and its column index. All
    # reads and writes go straight to the row's parallel arrays (`attrs`,
    # `chars`) and the sparse grapheme overlay.
    #
    # This keeps the contiguous-array memory layout (benchmarks in
    # `benchmarks/cells-vs-arrays.cr` show ~2.7x faster than a heap-allocated
    # `class Cell`) while preserving the familiar `line[x].attr = ...`
    # mutation API used throughout rendering and drawing.
    #
    # Grapheme support (Phase 1): the common case — one codepoint per cell —
    # is stored directly in `chars : Array(Char)` for speed. A cell holding a
    # multi-codepoint **grapheme cluster** (e.g. base + combining mark) keeps
    # its *base* codepoint in `chars` and the full cluster in the row's sparse
    # `graphemes` overlay (allocated lazily). A **wide** (2-column) grapheme
    # occupies two cells: the grapheme cell and a following *continuation*
    # cell (`CONTINUATION` sentinel) the draw loop emits nothing for. Legacy
    # (non-`full_unicode`) rendering never creates overlay or continuation
    # cells, so its fast path is unchanged.
    struct Cell
      include Comparable(self)

      # Sentinel stored in `chars` for the trailing cell of a wide grapheme. The
      # draw loop emits nothing for it — the wide glyph already advanced the
      # cursor by two columns. NUL never appears in real content (control chars
      # are stripped by `process_content`).
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
      # had — and any hyperlink: every content write clears the link overlay,
      # so a link exists only while a link-aware writer keeps re-asserting it
      # via `#link=`. Cheap on the legacy hot path: with no overlays, both
      # deletes are just nil checks.
      def char=(value : Char) : Char
        @row.chars.unsafe_put(@index, value)
        @row.delete_grapheme @index
        @row.delete_link @index
        value
      end

      # The cell's full grapheme cluster as a `String`: the overlay cluster if
      # present, else the single codepoint (`""` for a continuation cell).
      #
      # NOTE: this always allocates (an overlay clone or `char.to_s`). On hot
      # paths prefer `#grapheme_overlay` (nil, no alloc, for single-codepoint
      # cells) or `#grapheme_eq?` (allocation-free comparison).
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
        @row.delete_link @index
        value
      end

      # The overlay cluster for this cell, or `nil` if it holds at most one
      # codepoint. Used for fast, allocation-free equality on the diff path.
      def grapheme_overlay : String?
        @row.grapheme_at?(@index)
      end

      # Whether this cell's grapheme equals `value`, without materializing the
      # cell's own grapheme as a `String` first. Mirrors `grapheme == value`
      # (see `#grapheme`), but on the common single-codepoint cell does only a
      # `Char` compare — no allocation — since this drives the per-cell diff
      # guard in `widget_rendering`.
      def grapheme_eq?(value : String) : Bool
        if g = @row.grapheme_at?(@index)
          g == value
        else
          c = @row.chars.unsafe_fetch(@index)
          if c == CONTINUATION
            value.empty?
          elsif value.size == 1
            value[0] == c
          else
            false
          end
        end
      end

      # Whether this is the trailing cell of a wide grapheme (draw emits nothing).
      def continuation? : Bool
        @row.chars.unsafe_fetch(@index) == CONTINUATION
      end

      # Marks this cell as the continuation of the preceding wide grapheme.
      # Clears any hyperlink, like every content write; a linked wide glyph's
      # writer re-asserts the link on both cells (see `#link=`).
      def continuation! : Nil
        @row.chars.unsafe_put(@index, CONTINUATION)
        @row.delete_grapheme @index
        @row.delete_link @index
      end

      # The cell's OSC 8 hyperlink id (an index into the owning window's link
      # registry, see `Window#link_id`); `0` = no link.
      def link : UInt16
        @row.link_at(@index)
      end

      # Sets the cell's hyperlink id (`0` clears). Marks the column dirty on a
      # real change, so a link-only change (same glyph and attr, different
      # target) still reaches the terminal. Call *after* the content write —
      # `char=`/`grapheme=`/`continuation!` clear the link overlay.
      def link=(id : UInt16) : UInt16
        if @row.link_at(@index) != id
          id == 0 ? @row.delete_link(@index) : @row.set_link(@index, id)
          @row.mark_dirty @index
        end
        id
      end

      # Display width of this cell in terminal columns (0 for a continuation
      # cell, 1 or 2 otherwise).
      #
      # The common single-codepoint cell takes the `Char` overload of
      # `Unicode.width`, avoiding the `String` allocation `grapheme` (`c.to_s`)
      # would incur — called once per cell in the draw loop. Only a real
      # multi-codepoint cluster needs the `String` path, where VS16/
      # regional-indicator promotion can apply.
      def width : Int32
        if g = @row.grapheme_at?(@index)
          ::Crysterm::Unicode.width g
        else
          c = @row.chars.unsafe_fetch(@index)
          c == CONTINUATION ? 0 : ::Crysterm::Unicode.width(c)
        end
      end

      # Cell-vs-cell equality compares *values* (attr + grapheme), not handle
      # identity, so cells from different rows (e.g. `@lines` vs `@olines`) can
      # be diffed during drawing.
      #
      # Fast path: compares `attr` and the base `char` first, then the overlay
      # references. For the common single-codepoint cell both overlays are
      # `nil`, so no `String` is allocated.
      def ==(other : Cell)
        attr == other.attr && char == other.char && grapheme_overlay == other.grapheme_overlay
      end

      # Cell-vs-tuple equality compares cell *values* (attr + char). Drives the
      # diffing renderer: the unchanged-cell skip in `screen_drawing`
      # (`ox == {desired_attr, desired_char}`), the BCE line-clear (`line[xx] !=
      # {desired_attr, ' '}`), and the `cell != {attr, ch}` write guards in
      # `widget_rendering`/`fill_region`. A cell holding a multi-codepoint
      # cluster is never equal to a single-char tuple, so such writes are not
      # skipped.
      #
      # The `legacy_cell_eq` compile flag forces this to constant-false for A/B
      # testing/benchmarking against a full-repaint path (the tuple compare never
      # matches, so every frame fully repaints).
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

      # Writes *attr*/*char* into this cell only when they differ from what it
      # already holds (a grapheme-cluster overlay always counts as differing,
      # see `#==(Tuple)`), and marks the column dirty on a real change. This is
      # the per-cell write-if-changed guard the render loops in
      # `widget_rendering` repeat.
      @[AlwaysInline]
      def set_if_changed(attr : Int64, char : Char) : Nil
        if self != {attr, char}
          self.attr = attr
          self.char = char
          @row.mark_dirty @index
        end
      end

      # Marks this cell's column dirty, narrowing the owning row's dirty range
      # to include it (unlike a plain `line.dirty = true`, which conservatively
      # widens to the whole row). For callers that mutate a cell directly
      # (e.g. `Window#blend_region`/`#tint_region`) and want the same
      # column-narrowing `#mark_dirty` that `fill_region`/`Plane#composite_onto`
      # already use.
      @[AlwaysInline]
      def mark_dirty : Nil
        @row.mark_dirty @index
      end
    end

    # A single screen row.
    #
    # Storage is two parallel arrays (`attrs` of `Int64`, `chars` of `Char`)
    # rather than an array of cell objects, giving a contiguous, cache-friendly
    # layout for per-cell scans in rendering and drawing. `Indexable(Cell)`
    # provides `[]`, `[]?`, `each`, etc.; indexing returns a `Cell` handle into
    # this row.
    #
    # Multi-codepoint grapheme clusters are kept in a sparse `@graphemes`
    # overlay (index -> cluster), allocated only when a cluster is stored, so
    # rows of plain text carry no extra memory.
    #
    # NOTE: backed by plain `Array`s + `Indexable(Cell)` rather than subclassing
    # `Array(Cell)`. Subclassing a stdlib generic is deprecated and promotes
    # every `Array(Cell)` in the program (including unrelated shards) to the
    # virtual type `Array(Cell)+`, producing confusing compile errors far from
    # here (issue #30).
    class Row
      include Indexable(Cell)

      getter dirty = false

      # Inclusive range of columns changed since the last `draw`, so the draw
      # diff can scan only `[dirty_min, dirty_max]` instead of the whole row.
      # Empty when not dirty (`min > max`). A writer that knows the column it
      # changed calls `#mark_dirty(x)` to narrow it; a plain `dirty = true`
      # widens to the full row — the safe default for un-converted writers.
      # `Int32::MAX` as `dirty_max` means "to end of row".
      getter dirty_min : Int32 = Int32::MAX
      getter dirty_max : Int32 = Int32::MIN

      # Plain dirty toggle. Setting `true` conservatively marks the *whole* row
      # dirty (full-width scan); setting `false` clears the range. Column-aware
      # writers should prefer `#mark_dirty`.
      def dirty=(value : Bool) : Bool
        @dirty = value
        if value
          @dirty_min = 0
          @dirty_max = Int32::MAX
        else
          @dirty_min = Int32::MAX
          @dirty_max = Int32::MIN
        end
        value
      end

      # Marks column *x* dirty, widening the dirty range to include it. Multiple
      # writers in a frame union naturally (min/max), and a prior full
      # `dirty = true` stays full. Inlined: called per changed cell in the
      # render hot loops (`widget_rendering`/`fill_region`).
      @[AlwaysInline]
      def mark_dirty(x : Int32) : Nil
        @dirty = true
        @dirty_min = x if x < @dirty_min
        @dirty_max = x if x > @dirty_max
      end

      getter attrs : Array(Int64)
      getter chars : Array(Char)

      # Sparse overlay of multi-codepoint grapheme clusters (cell index ->
      # cluster). Lazily allocated; nil for rows holding only single codepoints.
      @graphemes : Hash(Int32, String)? = nil

      # Sparse overlay of OSC 8 hyperlink ids (cell index -> id in the owning
      # window's link registry; see `Window#link_id`). Lazily allocated; nil
      # for rows with no linked cells — the common case, so per-cell probes on
      # hot paths are a nil check.
      @links : Hash(Int32, UInt16)? = nil

      def initialize
        @attrs = Array(Int64).new
        @chars = Array(Char).new
      end

      # Reserves capacity for `initial_capacity` cells but creates an empty
      # (size 0) row. The `cell` argument is accepted but ignored, matching an
      # `Array(Cell).new(capacity, cell)` signature.
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

      # Whether this row carries any multi-codepoint grapheme-cluster overlay.
      # Lets a per-cell consumer (e.g. `Plane#composite_onto`) skip the
      # `grapheme_at?` hash probe on the common all-single-codepoint row.
      def has_graphemes? : Bool
        if g = @graphemes
          !g.empty?
        else
          false
        end
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

      # Whether this row has any hyperlinked cell. Lets the draw loop skip
      # the per-cell link probes on the common link-free row.
      def has_links? : Bool
        if l = @links
          !l.empty?
        else
          false
        end
      end

      # The hyperlink id stored at `index`; `0` = no link.
      def link_at(index : Int) : UInt16
        @links.try(&.[index.to_i32]?) || 0_u16
      end

      # Stores hyperlink id *id* at `index` (allocating the overlay on first
      # use). `Cell#link=` is the usual writer.
      def set_link(index : Int, id : UInt16) : Nil
        (@links ||= {} of Int32 => UInt16)[index.to_i32] = id
      end

      # Drops any hyperlink at `index`. Cheap when no overlay exists.
      def delete_link(index : Int) : Nil
        @links.try &.delete(index.to_i32)
      end

      # Resets every cell to *attr*/*char* (and drops any grapheme/link
      # overlay). Used to clear a `Plane`'s buffer to its transparent sentinel
      # each frame.
      def clear_to(attr : Int64, char : Char) : Nil
        @attrs.fill attr
        @chars.fill char
        @graphemes.try &.clear
        @links.try &.clear
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

      # Removes the last cell (and any overlays it carried).
      def pop : Nil
        delete_grapheme(@attrs.size - 1)
        delete_link(@attrs.size - 1)
        @attrs.pop
        @chars.pop
      end
    end
  end
end
