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
  # (`Array(Array(String))`); everything else used here (`@maxes`, `pad`,
  # `cell_align`, the cell-border flags) is defined by the module itself, and
  # `@width`/`#str_width`/`#clean_tags` are inherited from `Widget`.
  module TableLayout
    # Computed per-column widths, filled in by `#calculate_maxes`.
    @maxes = [] of Int32

    # Whether `@maxes` needs recomputing. `#calculate_maxes` runs on every
    # `render` but only depends on `@rows`, `@width` and `@pad`, which change
    # exclusively through `#set_data` and `#pad=` (both set this). Skips the
    # per-frame re-scan of every cell when nothing relevant changed.
    @maxes_dirty : Bool = true

    # Extra padding added to each column when the table is sized to its
    # content (i.e. when no fixed `width` is set).
    getter pad : Int32 = 2

    # Setting `pad` invalidates the cached column widths.
    def pad=(value : Int32)
      @pad = value
      @maxes_dirty = true
    end

    # Marks the cached column widths (`@maxes`) stale so the next
    # `#calculate_maxes` recomputes them. Called by the table widgets from
    # `#set_data`.
    def invalidate_maxes
      @maxes_dirty = true
    end

    # When true, no internal cell borders are drawn (only the outer border,
    # if any).
    property? no_cell_borders : Bool = false

    # When true, internal cell-border junctions take the background color of
    # the cell they sit in, rather than the border background.
    property? fill_cell_borders : Bool = false

    # Horizontal alignment of cell text *within its column*. Kept separate from
    # the widget's own `@align`: for `Table`, box align must stay top-left so
    # it doesn't pad every line to the full box width and defeat
    # shrink-to-content sizing; for `ListTable`, it decouples cell alignment
    # from list-item alignment. Applied in `#pad_cell`.
    # ameba:disable Lint/UselessAssign
    Crystallabs::Helpers::Enums.enum_property cell_align : Tput::AlignFlag = Tput::AlignFlag::Center

    # Computes per-column widths from the current `@rows`. When a fixed numeric
    # `width` is set and large enough, the slack is distributed evenly across
    # columns; otherwise each column is sized to its widest cell plus `@pad`.
    def calculate_maxes
      return @maxes unless @maxes_dirty
      @maxes_dirty = false

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

      # Columns fill the box interior (inside border/padding), so slack is
      # distributed against `@width - iwidth`, not the full outer `@width`.
      # Targeting the full width would leave `row_width` one short, causing
      # `Table#set_data`'s `@width = row_width + iwidth` to grow the table by
      # `iwidth - 1` columns per call — a feedback loop widening the table
      # beyond what was requested.
      if (inner = numeric_inner_width) && inner >= min_row
        missing = inner - min_row
        per = missing // maxes.size
        rem = missing % maxes.size
        maxes = maxes.map_with_index do |max, i|
          i == maxes.size - 1 ? max + per + rem : max + per
        end
      else
        maxes = maxes.map { |max| max + @pad }
      end

      @maxes = maxes
    end

    # The interior content width when a fixed numeric `width` is set, i.e. the
    # box width minus the border/padding insets the columns render inside of.
    private def numeric_inner_width : Int32?
      (w = @width).is_a?(Int32) ? w - iwidth : nil
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
    # *first_col* drops the leading columns (used by `ListTable`'s column-level
    # horizontal scroll); the default `0` renders the whole row. The emitted row
    # begins at column *first_col* with no leading separator.
    #
    # A trailing space is appended so the row is one column wider than its
    # visible content: `Widget#_render`'s draw loop (`while x < xl - 1`) never
    # paints the final content column, so without this spare column a last
    # cell filled to its full width would lose its last character.
    # `#row_width` accounts for this extra column.
    def render_row(row : Array(String), first_col : Int32 = 0) : String
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
    # separators before it). Used by `ListTable` to snap the horizontal scroll
    # offset to a column boundary. `offsets.size == @maxes.size`.
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
    # display column *base_x* (the left content inset, `ileft`). Used by the
    # table widgets to resolve a CSS per-cell style from an x position:
    # `Table` maps every column (`start_col == 0`), `ListTable` maps from its
    # first horizontally-visible column (`@first_col`).
    def col_for_x(start_col : Int32, base_x : Int32) : Hash(Int32, Int32)
      map = {} of Int32 => Int32
      cx = base_x
      (start_col...@maxes.size).each do |col_i|
        max = @maxes[col_i]
        (cx...cx + max).each { |xpos| map[xpos] = col_i }
        # Skip the single inter-column separator `#render_row` emits between
        # cells (matching `#column_start_offsets`'s `acc += m + 1`). Without
        # this `+ 1` the mapping would drift left by one cell per preceding column.
        # The separator cell itself stays unmapped (a gridline gap).
        cx += max + 1
      end
      map
    end

    # Cached x→column map from `#col_for_x`, keyed on the inputs it depends
    # on (`@maxes`, `ileft`, and *first_col*). `col_for_x` itself is cheap to
    # call but callers (`Table#draw_borders`, `ListTable#recolor_css_cells`)
    # run every frame, so this avoids rebuilding the `Hash` each time.
    # Rebuilt only when `@maxes`, `ileft`, or *first_col* changes.
    #
    # *first_col* is `0` for `Table` (maps every column) and `@first_col` for
    # `ListTable` (maps from its first horizontally-visible column).
    @col_for_x_cache : Hash(Int32, Int32)? = nil
    @col_for_x_cache_maxes : Array(Int32)? = nil
    @col_for_x_cache_ileft : Int32 = -1
    @col_for_x_cache_first_col : Int32 = -1

    def cached_col_for_x(first_col : Int32 = 0) : Hash(Int32, Int32)
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

    # Pads/clips a single cell's text to `width` columns according to the
    # widget's horizontal alignment, returning the result as a new `String`.
    # Prefer `#pad_cell_to` on the render path, which writes straight into the
    # row builder without this intermediate allocation; this wrapper is kept for
    # callers/tests that want the padded cell in isolation.
    def pad_cell(cell : String, width : Int32) : String
      String.build { |io| pad_cell_to io, cell, width }
    end

    # Writes *cell*, padded/clipped to *width* columns per the widget's
    # horizontal alignment, straight to *io* — no per-cell `String` (and, on the
    # clip path, no `graphemes` array / per-grapheme `String`) intermediates.
    # This is the hot path: `#render_row` calls it per cell per row rebuild, i.e.
    # N×M times per `set_data` and per `ListTable` horizontal-scroll tick.
    def pad_cell_to(io : IO, cell : String, width : Int32) : Nil
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
          # remaining suffix fits. The suffix is maximal with width <= *width*,
          # equivalently the smallest leading run whose width reaches
          # `clen - width` (see the reverse-greedy proof this mirrors).
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
          kept = 0
          end_byte = 0
          cell.each_grapheme do |g|
            gw = fu ? Unicode.width(g) : g.size
            break if kept + gw > width
            kept += gw
            end_byte += g.bytesize
          end
          io << cell.byte_slice(0, end_byte)
        end
      else
        io << cell
      end
    end

    # Normalizes arbitrary row data into rows of string cells.
    def normalize_rows(rows) : Array(Array(String))
      return [] of Array(String) unless rows
      rows.map { |row| row.map(&.to_s) }
    end

    # Applies the optional cell-border/padding constructor options, each only
    # when explicitly given (`nil` leaves the default). Shared by the table
    # widgets' `#initialize`. Ivars assigned directly (not via `pad=`) since
    # the cache is rebuilt by the following `#set_data` anyway.
    def init_cell_options(pad, no_cell_borders, fill_cell_borders) : Nil
      pad.try { |v| @pad = v }
      no_cell_borders.try { |v| @no_cell_borders = v }
      fill_cell_borders.try { |v| @fill_cell_borders = v }
    end

    # Normalizes *rows* into `@rows` and recomputes the cached column widths.
    # Returns `false` when the table ends up with no columns, so a `#set_data`
    # caller can early-return on an empty table via
    # `return unless reload_rows(rows)`.
    def reload_rows(rows) : Bool
      @rows = normalize_rows rows
      invalidate_maxes
      calculate_maxes
      !@maxes.empty?
    end

    # Interior extent of the rendered table for *coords*, shared by the border
    # and CSS-recolor passes: the content origin (`xi`, `yi`) plus the content
    # `width`/`height` reaching the right/bottom insets. Destructure as
    # `xi, yi, width, height = border_extent(coords)`.
    def border_extent(coords) : Tuple(Int32, Int32, Int32, Int32)
      {coords.xi, coords.yi, coords.xl - coords.xi - iright, coords.yl - coords.yi - ibottom}
    end

    # The attribute for an internal cell-border junction: either the plain
    # border attribute, or (with `fill_cell_borders`) the border
    # flags/foreground laid over the existing cell's background.
    def junction_attr(battr : Int64, over : Int64) : Int64
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
    def draw_vertical_separators(line, xi : Int32, battr : Int64,
                                 start_col : Int32 = 0, width : Int32? = nil) : Nil
      # `rx` is the pure within-content column offset (0 == first content
      # column); the separator after column `mi` sits at content offset
      # `sum(maxes[..mi])`. Paint it at `xi + ileft + rx`: content begins at the
      # left inset (`ileft`), not a hardcoded one column. Using `xi + rx + 1`
      # would assume `ileft == 1`, so a bordered+padded table would draw
      # separators one cell short of the cells they divide.
      rx = 0
      g_v = glyph Glyphs::Role::LineVertical
      (start_col...(@maxes.size - 1)).each do |mi|
        rx += @maxes[mi]
        # Clip against the *content* width: *width* as passed by callers is
        # `xl - xi - iright`, which still includes the left inset the separator
        # is painted past (`xi + ileft + rx`) — comparing bare `rx` overshot the
        # content edge by `ileft` columns on a padded/bordered table.
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
