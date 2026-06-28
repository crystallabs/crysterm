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

    # Whether `@maxes` needs recomputing. `#calculate_maxes` is called on every
    # `render` but only depends on `@rows`, `@width` and `@pad`; those change
    # exclusively through `#set_data` (invoked on data change, attach and
    # resize) and `#pad=`, both of which set this. Caching skips the per-frame
    # re-scan of every cell (each `clean_tags`/`str_width`) when nothing
    # relevant changed.
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

    # Horizontal alignment of cell text *within its column*. Kept separate
    # from the widget's own `@align`: for `Table`, the box align must stay at
    # the default (top-left) so it doesn't pad every line out to the full box
    # width and defeat shrink-to-content sizing; for `ListTable`, it keeps the
    # cell alignment independent of the list-item alignment. The cells are
    # already aligned here in `#pad_cell`.
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

      # Columns fill the box *interior* (inside the border/padding), so any
      # slack is distributed against `@width - iwidth`, not the full outer
      # `@width`. Targeting the full width left `row_width` one short of the
      # interior, so `Table#set_data`'s `@width = row_width + iwidth` grew the
      # table by `iwidth - 1` columns on every call — a feedback loop that made
      # a fixed-width table creep wider than requested.
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
    # and SGR sequences stripped — they occupy no columns once the content is
    # parsed and rendered. Measuring the raw string (as `str_width` does)
    # would over-count tagged cells by the length of their tags, throwing off
    # column widths and the border separators that are positioned from them.
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
    # visible content: Crysterm's content draw loop (`while x < xl - 1` in
    # `Widget#_render`) never paints the final content column, so without this
    # spare column a last cell filled to its full width would lose its last
    # character. `#row_width` accounts for this extra column.
    def render_row(row : Array(String), first_col : Int32 = 0) : String
      String.build do |str|
        ci = first_col
        while ci < row.size
          str << ' ' unless ci == first_col
          str << pad_cell(row[ci], @maxes[ci]? || cell_width(row[ci]))
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
    # output: `offsets[c] = @maxes[0...c].sum + c` (the `+ c` for the one-column
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
        # Skip the single inter-column separator that `#render_row` emits between
        # cells (and that `#column_start_offsets` accounts for with `acc += m + 1`).
        # Without this `+ 1` the mapping drifted left by one cell per preceding
        # column, so per-cell CSS styles landed on the wrong column for every
        # column past the first. The separator cell itself stays unmapped (no
        # cell style — it's a gridline gap), matching the rendered layout.
        cx += max + 1
      end
      map
    end

    # Pads/clips a single cell's text to `width` columns according to the
    # widget's horizontal alignment.
    def pad_cell(cell : String, width : Int32) : String
      clen = cell_width cell
      align = cell_align

      if clen < width
        # Distribute the padding per alignment. For centered text an odd
        # remainder goes to the right side, matching the original loop (which
        # added a leading + trailing space per round, overshot by one on odd
        # widths, then trimmed one leading space back off).
        pad = width - clen
        left, right =
          if align.h_center?
            l = pad // 2
            {l, pad - l}
          elsif align.right?
            {pad, 0}
          else
            {0, pad}
          end

        String.build do |s|
          left.times { s << ' ' }
          s << cell
          right.times { s << ' ' }
        end
      elsif clen > width
        # Trim whole characters until the column count fits (or the cell
        # empties first), from the front for centered/right-aligned text and
        # from the end otherwise. `clen` counts display columns while the trim
        # removes characters one-for-one, so the count is capped at the
        # character length — exactly as the original per-character loop did.
        remove = Math.min(clen - width, cell.size)
        if align.h_center? || align.right?
          cell[remove..]
        else
          cell[0, cell.size - remove]
        end
      else
        cell
      end
    end

    # Normalizes arbitrary row data into rows of string cells.
    def normalize_rows(rows) : Array(Array(String))
      return [] of Array(String) unless rows
      rows.map { |row| row.map(&.to_s) }
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
    # grid `line`, accumulating the display position `rx` across the visible
    # columns starting at *start_col* (`0` for `Table`, `@first_col` for
    # `ListTable`'s horizontally-scrolled viewport). When *width* is given, the
    # run stops once a separator would fall at or past the right content edge
    # (`ListTable`'s clip); a nil *width* draws every internal column (`Table`,
    # which sizes itself to its content and never clips). Each separator takes
    # `junction_attr` so `fill_cell_borders` shows through. *xi* is the line's
    # left content origin (`coords.xi`).
    def draw_vertical_separators(line, xi : Int32, battr : Int64,
                                 start_col : Int32 = 0, width : Int32? = nil) : Nil
      rx = 0
      (start_col...(@maxes.size - 1)).each do |mi|
        rx += @maxes[mi]
        break if width && rx >= width
        next unless line[xi + rx + 1]?
        rx += 1
        if cell = line[xi + rx]?
          cell.attr = junction_attr(battr, cell.attr)
          cell.char = '│'
          line.dirty = true
        end
      end
    end
  end
end
