module Crysterm
  # Shared column-sizing and cell-padding logic for the table widgets
  # (`Widget::Table` and `Widget::ListTable`).
  #
  # This is a *content* layout: unlike the child-arranging engines under
  # `Layout` (which position child widgets), it lays out cell text *inside* a
  # single widget's own content, so it is mixed into the table widgets rather
  # than installed as a `Widget#layout`.
  #
  # The including widget must provide an `@rows` instance variable
  # (`Array(Array(String))`); everything else used here (`@maxes`, `column_spacing`,
  # `cell_align`, the cell-border flags) is defined by the module itself, and
  # `@width`/`#str_width`/`#clean_tags` are inherited from `Widget`.
  module TableLayout
    # Sort direction for `Widget::ListTable#sort_by_column`. Declared on the
    # shared `TableLayout` mixin (rather than on `ListTable` alone) so a future
    # sortable `Widget::Table` could reuse it too.
    enum SortOrder
      Ascending
      Descending
    end

    # Computed per-column widths, filled in by `#compute_column_widths`.
    @maxes = [] of Int32

    # Whether `@maxes` needs recomputing. `#compute_column_widths` runs every
    # `render` but depends only on `@rows`, `@width` and `@column_spacing`,
    # which change exclusively through `#rows=` and `#column_spacing=` — both
    # of which set this. Skips the per-frame re-scan of every cell when
    # nothing relevant changed.
    @maxes_dirty : Bool = true

    # The `{@width, ihorizontal, @column_spacing}` under which `@maxes` was last
    # computed. `ihorizontal` (border/padding insets) has no setter that trips
    # `@maxes_dirty` and changes silently when the CSS cascade first runs (after
    # the constructor's `#rows=`, with no `Resize` since the outer `@width` is
    # unchanged), so the dirty flag alone would leave the fixed-width slack
    # distributed over the pre-cascade interior. Comparing the key recomputes
    # exactly when a dependency moved; for content-sized tables `@width` is nil
    # and the key stays stable, so the cache still hits every frame.
    @maxes_key : Tuple(Dim | Int32 | String | Nil, Int32, Int32)? = nil

    # Extra padding added to each column when the table is sized to its
    # content (i.e. when no fixed `width` is set).
    getter column_spacing : Int32 = 2

    # Setting `column_spacing` invalidates the cached column widths.
    def column_spacing=(value : Int32)
      @column_spacing = value
      @maxes_dirty = true
    end

    # Marks the cached column widths (`@maxes`) stale so the next
    # `#compute_column_widths` recomputes them.
    def invalidate_column_widths
      @maxes_dirty = true
    end

    # When true (default), internal cell borders are drawn between cells. When
    # false, only the outer border (if any) is drawn.
    property? cell_borders : Bool = true

    # When true, internal cell-border junctions take the background color of
    # the cell they sit in, rather than the border background.
    property? fill_cell_borders : Bool = false

    # Horizontal alignment of cell text *within its column*. Kept separate from
    # the widget's own `@align`: for `Table`, box align must stay top-left so it
    # doesn't pad every line to the full box width and defeat shrink-to-content
    # sizing; for `ListTable`, it decouples cell alignment from list-item
    # alignment.
    # ameba:disable Lint/UselessAssign
    Crystallabs::Helpers::Enums.enum_property cell_align : Tput::AlignFlag = Tput::AlignFlag::Center

    # Computes per-column widths from the current `@rows`. When a fixed numeric
    # `width` is set and large enough, the slack is distributed evenly across
    # columns; otherwise each column is sized to its widest cell plus
    # `@column_spacing`.
    def compute_column_widths
      key = {@width, ihorizontal, @column_spacing}
      return @maxes if !@maxes_dirty && @maxes_key == key
      @maxes_dirty = false
      @maxes_key = key

      @maxes = [] of Int32
      return @maxes if @rows.empty?

      maxes = [] of Int32
      @rows.each do |row|
        row.each_with_index do |cell, i|
          while maxes.size <= i
            maxes << 0
          end
          clen = cell_width cell
          maxes[i] = clen if maxes[i] < clen
        end
      end
      return @maxes if maxes.empty?

      # Minimum width of a rendered row: column contents, one separator
      # between each pair, plus the trailing spare column. This must match
      # `#row_width` exactly (`maxes.sum + maxes.size`).
      min_row = maxes.sum + maxes.size

      # Columns fill the box interior (inside border/padding), so slack must be
      # distributed against `@width - ihorizontal`, not the full outer `@width`.
      # Targeting the full width leaves `row_width` one short, and `Table#rows=`'s
      # `@width = row_width + ihorizontal` then grows the table by `ihorizontal -
      # 1` columns per call — a feedback loop.
      if (inner = numeric_inner_width) && inner >= min_row
        missing = inner - min_row
        per = missing // maxes.size
        rem = missing % maxes.size
        maxes = maxes.map_with_index do |max, i|
          i == maxes.size - 1 ? max + per + rem : max + per
        end
      else
        maxes = maxes.map { |max| max + @column_spacing }
      end

      @maxes = maxes
    end

    # The interior content width when a fixed numeric `width` is set, i.e. the
    # box width minus the border/padding insets the columns render inside of.
    private def numeric_inner_width : Int32?
      (w = @width).is_a?(Int32) ? w - ihorizontal : nil
    end

    # Visible display width of a cell in terminal columns, with `{...}` tags
    # and SGR sequences stripped (they occupy no columns once rendered).
    # Measuring the raw string would over-count tagged cells, throwing off
    # column widths and the border separators positioned from them.
    def cell_width(cell : String) : Int32
      str_width clean_tags(cell)
    end

    # Renders one row of cells into a string, padding each cell to its column
    # width and separating columns with a single space.
    #
    # *first_col* drops the leading columns; the default `0` renders the whole
    # row. The emitted row begins at column *first_col* with no leading
    # separator.
    #
    # A trailing space is appended so the row is one column wider than its
    # visible content: `Widget#base_render`'s draw loop (`while x < xl - 1`) never
    # paints the final content column, so without this spare column a last
    # cell filled to its full width would lose its last character.
    # `#row_width` accounts for this extra column.
    protected def render_row(row : Array(String), first_col : Int32 = 0) : String
      String.build do |str|
        ci = first_col
        while ci < row.size
          str << ' ' unless ci == first_col
          pad_cell_to str, row[ci], @maxes[ci]? || cell_width(row[ci])
          ci += 1
        end
        str << ' '
      end
    end

    # The display width of a rendered row (see `#render_row`), including the
    # inter-column separators and the trailing spare column.
    def row_width : Int32
      @maxes.sum + (@maxes.size - 1) + 1
    end

    # Display column at which each table column *starts* in a full `#render_row`
    # output: `offsets[c] = @maxes[0...c].sum + c` (`+ c` for the one-column
    # separators before it). `offsets.size == @maxes.size`.
    def column_start_offsets : Array(Int32)
      offs = [] of Int32
      acc = 0
      @maxes.each do |m|
        offs << acc
        acc += m + 1
      end
      offs
    end

    # Maps each interior text-column x to the `@maxes` column index it falls in,
    # packing columns left-to-right from *start_col* (inclusive) starting at
    # display column *base_x* (the left content inset, `ileft`). Resolves a
    # per-cell CSS style from an x position.
    def col_for_x(start_col : Int32, base_x : Int32) : Hash(Int32, Int32)
      map = {} of Int32 => Int32
      cx = base_x
      (start_col...@maxes.size).each do |col_i|
        max = @maxes[col_i]
        (cx...cx + max).each { |xpos| map[xpos] = col_i }
        # Skip the single inter-column separator `#render_row` emits between
        # cells, or the mapping drifts left by one cell per preceding column. The
        # separator cell itself stays unmapped (a gridline gap).
        cx += max + 1
      end
      map
    end

    # Cached x→column map from `#col_for_x`, rebuilt only when `@maxes`, `ileft`
    # or *first_col* changes — its callers run every frame and would otherwise
    # rebuild the `Hash` each time.
    #
    # *first_col* is `0` for `Table` (maps every column) and `@first_col` for
    # `ListTable` (maps from its first horizontally-visible column).
    @col_for_x_cache : Hash(Int32, Int32)? = nil
    @col_for_x_cache_maxes : Array(Int32)? = nil
    @col_for_x_cache_ileft : Int32 = -1
    @col_for_x_cache_first_col : Int32 = -1

    protected def cached_col_for_x(first_col : Int32 = 0) : Hash(Int32, Int32)
      cached = @col_for_x_cache
      if cached.nil? || !@maxes.same?(@col_for_x_cache_maxes) ||
         ileft != @col_for_x_cache_ileft || first_col != @col_for_x_cache_first_col
        cached = @col_for_x_cache = col_for_x(first_col, ileft)
        @col_for_x_cache_maxes = @maxes
        @col_for_x_cache_ileft = ileft
        @col_for_x_cache_first_col = first_col
      end
      cached
    end

    # Pads/clips a single cell's text to `width` columns according to the widget's
    # horizontal alignment, returning the result as a new `String`. Prefer
    # `#pad_cell_to` on the render path, which writes straight into the row
    # builder without this intermediate allocation.
    def pad_cell(cell : String, width : Int32) : String
      String.build { |io| pad_cell_to io, cell, width }
    end

    # Writes *cell*, padded/clipped to *width* columns per the widget's horizontal
    # alignment, straight to *io* — no per-cell `String` (and, on the clip path,
    # no `graphemes` array / per-grapheme `String`) intermediates. The hot path:
    # called per cell per row rebuild, i.e. N×M times per `#rows=`.
    protected def pad_cell_to(io : IO, cell : String, width : Int32) : Nil
      clen = cell_width cell
      align = cell_align

      if clen < width
        # Distribute padding per alignment; for centered text an odd remainder
        # goes to the right side.
        pad = width - clen
        left =
          if align.h_center?
            pad // 2
          elsif align.right?
            pad
          else
            0
          end
        left.times { io << ' ' }
        io << cell
        (pad - left).times { io << ' ' }
      elsif clen > width
        # Trim by accumulating display width until the content fits `width`
        # columns: from the front for centered/right-aligned text, from the end
        # otherwise. Wide (CJK/emoji) graphemes count as 2 columns under
        # `full_unicode?`, so trimming by grapheme width (not character count)
        # keeps wide-char cells aligned. Graphemes are never split. The kept
        # run is emitted as a single `byte_slice` view — no per-grapheme copies.
        fu = full_unicode?
        if align.h_center? || align.right?
          # Keep the trailing `width` columns: drop leading graphemes until the
          # remaining suffix fits. The maximal such suffix is what's left after
          # the smallest leading run whose width reaches `clen - width`.
          drop = clen - width
          acc = 0
          start_byte = 0
          cell.each_grapheme do |g|
            break if acc >= drop
            acc += fu ? Unicode.width(g) : g.size
            start_byte += g.bytesize
          end
          io << cell.byte_slice(start_byte)
        else
          # Keep the leading `width` columns: drop trailing graphemes.
          io << cell.byte_slice(0, Unicode.leading_byte_len(cell, width, fu))
        end
      else
        io << cell
      end
    end

    # Normalizes arbitrary row data into rows of string cells.
    protected def normalize_rows(rows) : Array(Array(String))
      return [] of Array(String) unless rows
      rows.map { |row| row.map(&.to_s) }
    end

    # Applies the optional cell-border/padding constructor options, each only when
    # explicitly given (`nil` leaves the default). Ivars are assigned directly
    # (not via `column_spacing=`) since the following `#rows=` rebuilds the cache
    # anyway.
    protected def init_cell_options(column_spacing : Int32?, cell_borders : Bool, fill_cell_borders : Bool) : Nil
      column_spacing.try { |v| @column_spacing = v }
      @cell_borders = cell_borders
      @fill_cell_borders = fill_cell_borders
    end

    # Normalizes *rows* into `@rows` and recomputes the cached column widths.
    # Returns `false` when the table ends up with no columns, so a `#rows=`
    # caller can early-return on an empty table via
    # `return unless reload_rows(rows)`.
    protected def reload_rows(rows) : Bool
      @rows = normalize_rows rows
      invalidate_column_widths
      compute_column_widths
      !@maxes.empty?
    end

    # Interior extent of the rendered table for *coords*: the content origin
    # (`xi`, `yi`) plus the content `width`/`height` reaching the right/bottom
    # insets. Destructure as `xi, yi, width, height = border_extent(coords)`.
    protected def border_extent(coords) : Tuple(Int32, Int32, Int32, Int32)
      {coords.xi, coords.yi, coords.width - iright, coords.height - ibottom}
    end

    # The attribute for an internal cell-border junction: either the plain
    # border attribute, or (with `fill_cell_borders`) the border
    # flags/foreground laid over the existing cell's background.
    protected def junction_attr(battr : Int64, over : Int64) : Int64
      return battr unless fill_cell_borders?
      Attr.pack Attr.flags(battr), Attr.fg(battr), Attr.bg(over)
    end

    # Draws the internal `│` vertical cell separators on a single already-fetched
    # grid `line`, accumulating display position `rx` across visible columns
    # starting at *start_col* (`0` for `Table`, `@first_col` for `ListTable`'s
    # scrolled viewport). When *width* is given, the run stops once a separator
    # would fall at/past the right content edge (`ListTable`'s clip); nil draws
    # every internal column (`Table` never clips). Each separator uses
    # `junction_attr` so `fill_cell_borders` shows through. *xi* is the line's
    # left content origin (`coords.xi`).
    protected def draw_vertical_separators(line, xi : Int32, battr : Int64,
                                           start_col : Int32 = 0, width : Int32? = nil) : Nil
      # `rx` is the pure within-content column offset (0 == first content column);
      # the separator after column `mi` sits at content offset `sum(maxes[..mi])`.
      # Paint it at `xi + ileft + rx` — content begins at the left inset, so an
      # `xi + rx + 1` form would assume `ileft == 1` and draw the separators of a
      # bordered+padded table one cell short of the cells they divide.
      rx = 0
      g_v = glyph Glyphs::Role::LineVertical
      (start_col...(@maxes.size - 1)).each do |mi|
        rx += @maxes[mi]
        # Clip against the *content* width: callers pass `width` as
        # `coords.width - iright`, which still includes the left inset the separator is
        # painted past (`xi + ileft + rx`), so comparing bare `rx` would overshoot
        # the content edge by `ileft` columns on a padded/bordered table.
        break if width && rx >= width - ileft
        # A separator left of the screen (negative absolute column, table
        # scrolled/positioned partly off the left edge) is skipped —
        # `Indexable#[]?` would wrap it to the row's right end.
        if (ax = xi + ileft + rx) >= 0 && (cell = line[ax]?)
          cell.attr = junction_attr(battr, cell.attr)
          cell.char = g_v
          line.dirty = true
        end
        rx += 1
      end
    end
  end
end
