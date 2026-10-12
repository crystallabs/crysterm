module Crysterm
  # A table of a document (Qt `QTextTable`), **pre-rendered**: the table
  # exists in the document as ordinary blocks holding its box-drawing
  # rendering — border rows plus one column-padded data row per table row —
  # every block referencing the same `TextTableFormat` instance (identity =
  # table identity, the `TextList` convention). That keeps the display-row ↔
  # document-position geometry of `Widget::TextEdit` exact with zero special
  # cases: caret, selection and copy treat a table as the text it looks like.
  #
  # This class is the structured *view* over those blocks: `#rows`/
  # `#columns`/`#cell_text` recover the grid, and the interchange exporters
  # use it to round-trip GFM/HTML tables.
  #
  # The table is also **editable**: `#cell_at` / `#cell_text_range` /
  # `#cell_cursor` locate cells by document position, `#set_cell_text` rewrites
  # one cell, and `#insert_row` / `#remove_row` / `#insert_column` /
  # `#remove_column` restructure the grid — each op re-renders the
  # padding/borders through the document's undoable editing API as ONE undo
  # step. Column ops move the table to a fresh `TextTableFormat` instance (the
  # column count is part of the format); this view follows it, but other views
  # over the old instance go empty and an undo restores the old instance, so
  # re-derive views after undo.
  #
  # Build one from a grid via `TextTable.build` (importers do), then insert
  # the returned blocks into a document.
  #
  # A table fits its document's `TextDocument#text_width` (Qt's
  # `QTextDocumentLayout` table layout): when its natural width is more,
  # the columns shrink (`.column_widths`) and the cells wrap at word
  # boundaries. A data row stays **one block** however many lines its
  # cells take: the block's text is its display lines one after another,
  # each exactly the table's width from bar to bar
  # (`│ a1 │ b1 ││ a2 │ b2 │`), so a view cuts it where one line's
  # closing bar meets the next line's opening one (`.display_lines`) —
  # nowhere else do two bars touch, a cell's own `│` being stored as `|`.
  # Row *r* is still block *k*, so source lines, `#row_block` and the
  # importers are unaffected. A wrapped cell's text is its pieces joined by
  # single spaces (`.split_data_row`); where that would not give the cell
  # back (a word broken in the middle), the table format remembers the cell
  # as it was (`TextTableFormat#wrapped_cells`). Its document positions are
  # no longer one run, so the cell is addressed as `{cell, offset in its
  # text}`: `#cell_offset` and `#cell_position`.
  class TextTable < TextBlockGroup
    getter format : TextTableFormat

    # `data_row_indexed`'s memo, valid while the document — fixed per
    # instance (`TextObject`) — still reports `@data_rows_revision`. Any
    # mutation bumps `TextDocument#revision`, so a stale memo can never be
    # served: the editing ops' own rebuilds invalidate it, and so do
    # external document edits by a holder of this (public API) view.
    @data_rows : Array({Int32, TextBlock})?
    @data_rows_revision : Int64 = -1

    def initialize(document : TextDocument, @format : TextTableFormat)
      super(document)
    end

    def member?(block : TextBlock) : Bool
      block.block_format.table_format.same?(@format)
    end

    def columns : Int32
      @format.columns
    end

    # Data rows (header + body); border rows are not counted.
    def rows : Int32
      data_blocks.size
    end

    # The block rendering 0-based data row *row*, or nil.
    def row_block(row : Int32) : TextBlock?
      return if row < 0
      data_blocks[row]?
    end

    # The trimmed text of cell (*row*, *column*), or nil when out of range.
    # A wrapped cell's lines are joined by single spaces.
    def cell_text(row : Int32, column : Int32) : String?
      return if column < 0
      b = row_block(row) || return
      TextTable.split_data_row(b.text, @format)[column]?
    end

    # === Cell cursors / editing ===

    # The `{row, column}` of the cell whose rendered segment contains
    # document position *pos*, or nil when *pos* is not on one of this
    # table's data rows (border rows have no cells). A position on a border
    # glyph snaps to the cell left of it; on a wrapped row, any line of a
    # cell is that cell.
    def cell_at(pos : Int32) : {Int32, Int32}?
      loc = document.block_at(pos)
      bi = loc.index
      off = loc.offset
      b = document.blocks[bi]? || return
      return unless member?(b) && TextTable.data_row?(b.text)
      row = nil
      data_row_indexed.each_with_index do |(i, _), r|
        if i == bi
          row = r
          break
        end
      end
      return unless row
      col = TextTable.column_at(b.text, off) || return
      {row, col.clamp(0, columns - 1)}
    end

    # Document positions of cell (*row*, *column*)'s trimmed text, or nil
    # when out of range. Empty for an empty cell (a caret can still sit
    # there); alignment padding around the text is excluded. A wrapped
    # cell's text is not one run of positions: the range then goes from its
    # first character to its last, over the other cells' pieces on the
    # lines between — address such a cell with `#cell_offset` and
    # `#cell_position` instead.
    def cell_text_range(row : Int32, column : Int32) : Range(Int32, Int32)?
      return if row < 0 || column < 0
      bi, b = data_row_indexed[row]? || return
      pieces, anchor = TextTable.cell_pieces(b.text, column) || return
      bp = document.block_position(bi)
      # All-spaces cell: an empty range at the left inner edge.
      return (bp + anchor)...(bp + anchor) if pieces.empty?
      (bp + pieces.first[1])...(bp + pieces.last[2])
    end

    # The offset in cell (*row*, *column*)'s text (`#cell_text`) that
    # document position *pos* stands for, or nil when out of range: a
    # position inside one of the cell's pieces is the matching character, one
    # on the cell's padding the nearest end of the piece on that line, and a
    # line the cell has no piece on is the cell's end. A position outside the
    # row's block is clamped to it. The inverse of `#cell_position`.
    def cell_offset(row : Int32, column : Int32, pos : Int32) : Int32?
      return if row < 0 || column < 0 || column >= columns
      bi, b = data_row_indexed[row]? || return
      off = (pos - document.block_position(bi)).clamp(0, b.size)
      TextTable.cell_offset_in(b.text, column, off, @format)
    end

    # The document position of *offset* (clamped) in cell (*row*,
    # *column*)'s text, or nil when out of range. An offset at the seam of
    # two lines of a wrapped cell is the end of the earlier line.
    def cell_position(row : Int32, column : Int32, offset : Int32) : Int32?
      return if row < 0 || column < 0 || column >= columns
      bi, b = data_row_indexed[row]? || return
      o = TextTable.cell_block_offset(b.text, column, offset, @format) || return
      document.block_position(bi) + o
    end

    # A cursor at the start of cell (*row*, *column*)'s text (Qt
    # `cellAt(...).firstCursorPosition()`), or nil when out of range.
    def cell_cursor(row : Int32, column : Int32) : TextCursor?
      pos = cell_position(row, column, 0) || return
      TextCursor.new(document, pos)
    end

    # The `{row, column}` after (*row*, *column*) in reading order — the last
    # cell of a row wraps to the next row's first — or nil past the last
    # cell. The grid geometry behind `TextCursor`'s `NextCell` and the
    # widget's Tab navigation.
    def next_cell(row : Int32, column : Int32) : {Int32, Int32}?
      column += 1
      if column >= columns
        column = 0
        row += 1
      end
      row < rows ? {row, column} : nil
    end

    # The `{row, column}` before (*row*, *column*) in reading order — the
    # first cell of a row wraps to the previous row's last — or nil before
    # the first cell.
    def previous_cell(row : Int32, column : Int32) : {Int32, Int32}?
      column -= 1
      if column < 0
        column = columns - 1
        row -= 1
      end
      row >= 0 ? {row, column} : nil
    end

    # Rewrites cell (*row*, *column*)'s text, re-rendering the column
    # padding (and borders when the column widens/narrows) at the document's
    # `TextDocument#text_width` — one undo step.
    # A newline in *text* becomes a space and a border glyph becomes an ASCII
    # '|' (the rebuild funnels through `sanitize_cell`, matching the import
    # path). Returns whether the cell existed.
    def set_cell_text(row : Int32, column : Int32, text : String) : Bool
      return false unless row >= 0 && column >= 0 && column < columns
      # `grid` already recovers every data row, so the row bound comes out of
      # its result — asking `#rows` first would scan the document once more.
      header, body = grid
      cells = row == 0 ? header : body[row - 1]?
      return false unless cells && column < cells.size
      cells[column] = text
      rebuild_content(header, body)
      true
    end

    # Inserts a blank data row so it becomes 0-based data row *at* (clamped
    # to 1..rows — the header stays row 0), re-rendering the table (one undo
    # step). Qt `insertRows` analog.
    def insert_row(at : Int32, cells : Array(String)? = nil) : Bool
      at = at.clamp(1, rows)
      header, body = grid
      row = (cells || [] of String).dup
      row = row[0, columns]
      row.concat(Array.new(columns - row.size, "")) if row.size < columns
      body.insert(at - 1, row)
      rebuild_content(header, body)
      true
    end

    # Removes 0-based data row *at* (1..rows-1; the header cannot be
    # removed). One undo step. Qt `removeRows` analog.
    def remove_row(at : Int32) : Bool
      return false if at < 1 || at >= rows
      header, body = grid
      return false if body.empty?
      body.delete_at(at - 1)
      rebuild_content(header, body)
      true
    end

    # Inserts a blank column at 0-based index *at* (clamped). The column
    # count lives on the `TextTableFormat`, so the table moves to a fresh
    # instance (see the class docs) — one undo step. Qt `insertColumns`.
    def insert_column(at : Int32, header_text : String = "") : Bool
      at = at.clamp(0, columns)
      header, body = grid
      header.insert(at, header_text)
      body.each(&.insert(at, ""))
      als = @format.alignments.try(&.dup)
      # A partial alignments array — fewer entries than columns, typical after
      # HTML import — would make `Array#insert(at, …)` raise IndexError for
      # `at > size`, so pad to full width first.
      als.try do |a|
        while a.size < columns
          a << Tput::AlignFlag::Left
        end
        a.insert(at, Tput::AlignFlag::Left)
      end
      ntf = TextTableFormat.new(columns: columns + 1, margin: @format.margin, border: @format.border?, alignments: als)
      rebuild_content(header, body, ntf)
      true
    end

    # Removes 0-based column *at*. The last column cannot be removed. One
    # undo step; moves the table to a fresh format instance like
    # `#insert_column`. Qt `removeColumns`.
    def remove_column(at : Int32) : Bool
      return false if at < 0 || at >= columns || columns == 1
      header, body = grid
      header.delete_at(at)
      body.each { |r| r.delete_at(at) if at < r.size }
      als = @format.alignments.try(&.dup)
      als.try { |a| a.delete_at(at) if at < a.size }
      ntf = TextTableFormat.new(columns: columns - 1, margin: @format.margin, border: @format.border?, alignments: als)
      rebuild_content(header, body, ntf)
      true
    end

    # The current grid as `{header cells, body rows}` (trimmed texts).
    private def grid : {Array(String), Array(Array(String))}
      texts = data_row_indexed.map { |(_, b)| TextTable.split_data_row(b.text, @format) }
      header = texts.first? || [] of String
      {header, texts.size > 1 ? texts[1..] : [] of Array(String)}
    end

    # `{block index, block}` of each data row, in document order. Memoized
    # on `TextDocument#revision`, so the repeated cell lookups of one
    # keystroke (`cell_at`, `cell_text_range` ×2, `grid`) share a single
    # document scan. Callers must not mutate the returned array.
    private def data_row_indexed : Array({Int32, TextBlock})
      rev = document.revision
      if (memo = @data_rows) && @data_rows_revision == rev
        return memo
      end
      res = [] of {Int32, TextBlock}
      document.blocks.each_with_index do |b, i|
        res << {i, b} if member?(b) && TextTable.data_row?(b.text)
      end
      @data_rows_revision = rev
      @data_rows = res
    end

    # The char format of the borders, recovered from *first_block* — the
    # table's first block, i.e. its top border row — so a rebuild keeps
    # whatever format the borders carry (the `rule` flag, or a hand-built
    # table's own). The block is a parameter because the callers have
    # already located it; deriving it here would re-scan the whole document.
    protected def self.border_char_format(first_block : TextBlock) : TextCharFormat
      first_block.fragments.first?.try(&.format) || TextCharFormat.default
    end

    # Replaces the table's rendered blocks with a fresh rendering of the
    # grid — per-block minimal text replaces, plus block splits/removes when
    # the row count changed — grouped into ONE undo step. *new_format*
    # (column ops) additionally moves every block to the new
    # `TextTableFormat` and re-points this view at it.
    private def rebuild_content(header : Array(String), body : Array(Array(String)), new_format : TextTableFormat? = nil) : Nil
      doc = document
      first_bi = nil
      old_count = 0
      doc.blocks.each_with_index do |b, i|
        if member?(b)
          first_bi ||= i
          old_count += 1
        end
      end
      return unless first_bi
      tf = new_format || @format
      first_block = doc.blocks[first_bi]
      base_bf = first_block.block_format
      bf = new_format ? base_bf.merge(TextBlockFormat.new(table_format: tf)) : base_bf
      # The cells the wrapped rows are remembered as before the build, which
      # remembers its own: a row whose rendering stays can still stand for
      # other cells (a space typed where a word was broken mid-way).
      remembered = {} of String => Array(String)?
      unless new_format
        doc.blocks[first_bi, old_count].each do |b|
          text = b.text
          remembered[text] = @format.wrapped_cells[text]? if text.includes?(TextTable::LINE_SEAM)
        end
      end
      fresh = TextTable.build_blocks(header, body, tf.alignments, tf.columns, bf, TextTable.border_char_format(first_block),
        TextTable.available_width(doc.text_width, base_bf))
      doc.edit do
        common = Math.min(old_count, fresh.size)
        (0...common).each do |k|
          bi = first_bi + k
          b = doc.blocks[bi]
          nb = fresh[k]
          if b.text == nb.text
            text = b.text
            if remembered.has_key?(text)
              was = remembered[text]
              now = @format.wrapped_cells[text]?
              doc.change_wrapped_cells(doc.block_position(bi), @format, text, was, now) unless was == now
            end
            next
          end
          bp = doc.block_position(bi)
          doc.remove(bp, b.size) if b.size > 0
          acc = bp
          nb.fragments.each do |f|
            doc.insert_text(acc, f.text, f.format)
            acc += f.size
          end
        end
        # Row count grew: split new blocks off the end of the run.
        (common...fresh.size).each do |k|
          bi = first_bi + k - 1
          pos = doc.block_position(bi) + doc.blocks[bi].size
          doc.insert_text(pos, "\n")
          acc = pos + 1
          fresh[k].fragments.each do |f|
            doc.insert_text(acc, f.text, f.format)
            acc += f.size
          end
        end
        # Row count shrank: remove the leftover blocks (with their leading
        # separators).
        (fresh.size...old_count).each do
          bi = first_bi + fresh.size
          bp = doc.block_position(bi)
          doc.remove(bp - 1, doc.blocks[bi].size + 1)
        end
        if ntf = new_format
          (0...fresh.size).each do |k|
            pos = doc.block_position(first_bi + k)
            doc.apply_block_format(pos, pos, TextBlockFormat.new(table_format: ntf), merge: true)
          end
          @format = ntf
        end
      end
    end

    # The data-row blocks, in document order. Shares `#data_row_indexed`'s
    # single pass rather than filtering `#blocks` (itself a full document
    # scan) a second time with the same predicate.
    private def data_blocks : Array(TextBlock)
      data_row_indexed.map { |(_, b)| b }
    end

    # === Rendering / recovery helpers (module-level, so importers/exporters
    # work on detached blocks) ===

    # The vertical border glyph the pre-rendered blocks use. Model-level
    # rendering is fixed to the Unicode tier, as importers run
    # widget-independent.
    protected def self.v_char : Char
      Glyphs[Glyphs::Role::LineVertical, Glyphs::Tier::Unicode]
    end

    # Normalizes cell content on its way into a pre-rendered block: collapses
    # '\n' to a space so the block never contains the block separator, and maps
    # a v_char inside the content to *v_to* (the build path passes '|') so grid
    # recovery (`split_data_row`) never mistakes it for a column boundary. The
    # single sanitize point for both the importers and the editing ops (which
    # reach it through `build_blocks`).
    protected def self.sanitize_cell(s : String, v_to : Char) : String
      s = s.gsub('\n', ' ')
      s = s.gsub(v_char, v_to) if s.includes?(v_char)
      s
    end

    # Whether pre-rendered block text is a data row (vs. a border row).
    def self.data_row?(text : String) : Bool
      text.starts_with?(v_char)
    end

    # Splits a pre-rendered data row back into trimmed cell texts. A wrapped
    # row's lines are split each, and every column's pieces joined by single
    # spaces — unless *format*, the row's table, remembers the row's cells
    # as they were (`TextTableFormat#wrapped_cells`). Without it, a word
    # that was broken in the middle comes back with a space at the break.
    def self.split_data_row(text : String, format : TextTableFormat? = nil) : Array(String)
      if format && (exact = format.wrapped_cells[text]?)
        return exact.dup
      end
      return split_data_line(text) unless text.includes?(LINE_SEAM)
      cells = [] of String
      display_lines(text).each do |line|
        split_data_line(line).each_with_index do |piece, i|
          if i >= cells.size
            cells << piece
          elsif !piece.empty?
            cells[i] = cells[i].empty? ? piece : "#{cells[i]} #{piece}"
          end
        end
      end
      cells
    end

    # One display line of a data row split into cell texts, trimmed of the
    # padding — ASCII spaces only, so a cell's own leading or trailing
    # Unicode space (U+00A0, U+3000, …) is kept, as `.cell_pieces` keeps it.
    private def self.split_data_line(text : String) : Array(String)
      cells = text.split(v_char)
      cells.shift if cells.first?.try(&.blank?)
      cells.pop if cells.last?.try(&.blank?)
      cells.map(&.strip(' '))
    end

    # Where two display lines of a wrapped row meet: the closing bar of one
    # and the opening bar of the next. Nowhere else in a row do two bars
    # touch — a cell is at least its two padding spaces wide, and a cell's
    # own `│` is stored as `|` (`.sanitize_cell`).
    LINE_SEAM = "││"

    # The display lines of pre-rendered row *text*, each the table's width:
    # one line for a border row or an unwrapped data row, one per line of
    # its tallest cell for a wrapped one. Joined they are *text*. What a
    # view shows of the row, and what reads the row as the grid it looks
    # like (a copy of the table as it reads) takes line by line. A piece of
    # a row (a copy of part of it) is cut at its seams the same way.
    def self.display_lines(text : String) : Array(String)
      return [text] unless text.includes?(LINE_SEAM)
      text.gsub(LINE_SEAM, "│\n│").split('\n')
    end

    # The block offsets of each display line's bars in row *text*, line by
    # line: a line starts at its first bar.
    protected def self.line_bars(text : String) : Array(Array(Int32))
      v = v_char
      lines = [] of Array(Int32)
      bars = [] of Int32
      prev = nil
      text.each_char_with_index do |c, i|
        if c == v
          if prev == v
            lines << bars
            bars = [] of Int32
          end
          bars << i
        end
        prev = c
      end
      lines << bars
      lines
    end

    # The index of the display line of *lines* (`.line_bars`) block offset
    # *off* is on: the last starting at or before it.
    private def self.line_of(lines : Array(Array(Int32)), off : Int32) : Int32
      line = 0
      lines.each_with_index do |bars, i|
        break if (bars.first? || 0) > off
        line = i
      end
      line
    end

    # The 0-based column of the cell block offset *off* of data row *text*
    # is in (a border glyph counts to the cell on its left, the opening bar
    # to the first), or nil for a row without cells.
    protected def self.column_at(text : String, off : Int32) : Int32?
      lines = line_bars(text)
      bars = lines[line_of(lines, off)]
      return if bars.size < 2
      (bars.count { |bp| bp < off } - 1).clamp(0, bars.size - 2)
    end

    # The pieces of cell *column* of data row *text*, one per display line
    # holding some of it: `{line, from, to}` block offsets of the trimmed
    # text. With them the anchor: the cell's inner left edge on the first
    # line, where an empty cell's caret sits. Nil when the row has no such
    # column.
    protected def self.cell_pieces(text : String, column : Int32) : {Array({Int32, Int32, Int32}), Int32}?
      return if column < 0
      chars = text.chars
      anchor = nil
      pieces = [] of {Int32, Int32, Int32}
      line_bars(text).each_with_index do |bars, line|
        next unless column + 1 < bars.size
        lo = bars[column] + 2     # past the bar and its pad space
        hi = bars[column + 1] - 1 # exclusive; before the trailing pad
        next if hi < lo
        anchor ||= lo
        while lo < hi && chars[lo] == ' '
          lo += 1
        end
        while hi > lo && chars[hi - 1] == ' '
          hi -= 1
        end
        pieces << {line, lo, hi} if hi > lo
      end
      anchor ? {pieces, anchor} : nil
    end

    # Where each of *pieces* (`.cell_pieces` of *text*) starts in the cell's
    # text *cell*: found in order, so a piece is wherever it follows the
    # last — after a space, or straight on where a word was broken.
    private def self.piece_starts(text : String, pieces : Array({Int32, Int32, Int32}), cell : String) : Array(Int32)
      at = 0
      pieces.map do |(_, lo, hi)|
        piece = text[lo, hi - lo]
        start = cell.index(piece, at) || at
        at = start + piece.size
        start
      end
    end

    # The offset in cell *column*'s text that block offset *off* of data row
    # *text* stands for (see `#cell_offset`).
    protected def self.cell_offset_in(text : String, column : Int32, off : Int32, format : TextTableFormat?) : Int32?
      pieces, _ = cell_pieces(text, column) || return
      cell = split_data_row(text, format)[column]? || ""
      return 0 if pieces.empty?
      starts = piece_starts(text, pieces, cell)
      line = line_of(line_bars(text), off)
      pieces.each_with_index do |(pl, lo, hi), k|
        return Math.min(starts[k] + (off - lo).clamp(0, hi - lo), cell.size) if pl == line
        return starts[k] if pl > line
      end
      cell.size
    end

    # The block offset of *offset* in cell *column*'s text of data row
    # *text* (see `#cell_position`).
    protected def self.cell_block_offset(text : String, column : Int32, offset : Int32, format : TextTableFormat?) : Int32?
      pieces, anchor = cell_pieces(text, column) || return
      return anchor if pieces.empty?
      cell = split_data_row(text, format)[column]? || ""
      starts = piece_starts(text, pieces, cell)
      pieces.each_with_index do |(_, lo, hi), k|
        return lo + (offset - starts[k]).clamp(0, hi - lo) if offset <= starts[k] + (hi - lo)
      end
      pieces.last[2]
    end

    # Whether *text* is a GFM table: a `|` header row, then a delimiter row of
    # `-`/`:`/`|`/spaces containing at least one `-`. The markd parser hands GFM
    # tables through as a plain paragraph, so they must be detected here.
    def self.gfm_table?(text : String) : Bool
      # A GFM table needs a `|` in its header row, so a pipe-free paragraph is
      # never one — cheap scan avoids the `lines` array allocation for it.
      return false unless text.includes?('|')
      lines = text.lines
      return false if lines.size < 2
      lines[0].includes?('|') &&
        lines[1].matches?(/\A\s*\|?[\s:|-]*-[\s:|-]*\|?\s*\z/) &&
        lines[1].includes?('-')
    end

    # Builds the pre-rendered blocks for a GFM table text. Returns nil when
    # *text* isn't one.
    def self.build_from_gfm(text : String) : Array(TextBlock)?
      return unless gfm_table?(text)
      rows = text.lines.map(&.strip).reject(&.empty?)
      header = split_gfm_row(rows[0])
      alignments = split_gfm_row(rows[1]).map { |c| gfm_align(c) }
      body = rows[2..]?.try(&.map { |r| split_gfm_row(r) }) || [] of Array(String)
      return if header.empty?
      build(header, body, alignments)
    end

    # Builds the pre-rendered blocks for a cell grid: top border, bold
    # *header* row, separator, *body* rows, bottom border — columns padded
    # to content width under the per-column *alignments*, and fitted to
    # *text_width* (`TextDocument#text_width`) when that is given.
    def self.build(header : Array(String), body : Array(Array(String)), alignments : Array(Tput::AlignFlag)? = nil, text_width : Int32? = nil) : Array(TextBlock)
      tf = TextTableFormat.new(columns: header.size, alignments: alignments)
      bf = TextBlockFormat.new(table_format: tf, non_breakable: true)
      # Borders are `rule`-flagged: structural line drawing a view colors from
      # its `rule` slot, and a distinct appearance from the cell text so the
      # two never merge into one fragment.
      build_blocks(header, body, alignments, header.size, bf, TextCharFormat.new(rule: true), available_width(text_width, bf))
    end

    # The width, bars included, a table whose blocks have format *bf* has of
    # the document's *text_width*: what the decorations a view lays out
    # beside the block leave (`TextBlockFormat#leading_inset_cells`,
    # `#frame_inset_cells`). Nil — no limit — for no text width.
    def self.available_width(text_width : Int32?, bf : TextBlockFormat) : Int32?
      text_width.try { |w| w - bf.leading_inset_cells - bf.frame_inset_cells }
    end

    # The column widths (content only, without the padding and bars) a grid
    # of *rows* renders with in *width* cells, bars included (Qt's
    # `QTextDocumentLayout` table layout). Without a width, or when it is
    # enough, every column is its widest cell. Otherwise the columns shrink
    # to fit: a column no wider than its fair share of the space keeps its
    # width, and the space left goes to the wider ones in proportion to
    # their widths, none narrower than its longest word. When even the
    # longest words do not fit, the widest columns give up cells down to
    # one glyph each, their words breaking. A table that cannot fit at one
    # glyph a column stays wider than *width*.
    def self.column_widths(rows : Array(Array(String)), cols : Int32, width : Int32?) : Array(Int32)
      natural = Array.new(cols, 0)
      rows.each do |row|
        row.each_with_index do |cell, i|
          natural[i] = Math.max(natural[i], Unicode.display_width(cell)) if i < cols
        end
      end
      return natural unless width
      avail = width - 3 * cols - 1
      return natural if natural.sum <= avail
      # The narrowest each column can go: its longest word, and below that
      # its widest glyph.
      word = Array.new(cols, 0)
      glyph = Array.new(cols, 0)
      rows.each do |row|
        row.each_with_index do |cell, i|
          next unless i < cols
          cell.split(' ') { |w| word[i] = Math.max(word[i], Unicode.display_width(w)) }
          cell.each_grapheme { |g| glyph[i] = Math.max(glyph[i], Unicode.width(g)) }
        end
      end
      widths = word.sum <= avail ? share_widths(natural, word, avail) : word.dup
      # Fix-up: while too wide, take a cell from the column with the most
      # above its longest word, then from the widest above its widest glyph.
      while widths.sum > avail
        i = (0...cols).select { |c| widths[c] > word[c] }.max_by? { |c| widths[c] - word[c] } ||
            (0...cols).select { |c| widths[c] > glyph[c] }.max_by? { |c| widths[c] }
        break unless i
        widths[i] -= 1
      end
      widths
    end

    # `.column_widths`' sharing of *avail* cells among columns of *natural*
    # widths, none below its *least*: the fair-share and proportional steps.
    private def self.share_widths(natural : Array(Int32), least : Array(Int32), avail : Int32) : Array(Int32)
      widths = natural.dup
      wide = (0...natural.size).to_a
      left = avail
      # Columns within their fair share keep their width; the share grows as
      # they leave theirs to the rest.
      loop do
        fair = wide.empty? ? 0 : left // wide.size
        narrow = wide.select { |i| natural[i] <= fair }
        break if narrow.empty?
        narrow.each { |i| left -= natural[i] }
        wide -= narrow
      end
      # The wide columns split the rest in proportion to their widths; one
      # whose share is below its least takes that, and the rest split again.
      loop do
        total = wide.sum { |i| natural[i] }
        held = wide.select { |i| total > 0 && Math.max(left, 0).to_i64 * natural[i] // total < least[i] }
        break if held.empty?
        held.each do |i|
          widths[i] = least[i]
          left -= least[i]
        end
        wide -= held
      end
      total = wide.sum { |i| natural[i] }
      wide.each { |i| widths[i] = (Math.max(left, 0).to_i64 * natural[i] // total).to_i }
      # Rounding leaves a few cells over: to the widest columns first.
      spare = left - wide.sum { |i| widths[i] }
      wide.sort_by { |i| -natural[i] }.cycle.each do |i|
        break if spare <= 0 || wide.none? { |c| widths[c] < natural[c] }
        next if widths[i] >= natural[i]
        widths[i] += 1
        spare -= 1
      end
      widths
    end

    # *cell* broken into lines of at most *width* cells at its spaces; a
    # word longer than *width* breaks where it reaches it.
    protected def self.wrap_cell(cell : String, width : Int32) : Array(String)
      return [cell] if width <= 0 || Unicode.display_width(cell) <= width
      lines = [] of String
      line = ""
      used = 0
      cell.split(' ') do |word|
        next if word.empty?
        ww = Unicode.display_width(word)
        if !line.empty? && used + 1 + ww <= width
          line = "#{line} #{word}"
          used += 1 + ww
          next
        end
        lines << line unless line.empty?
        line = ""
        used = 0
        if ww <= width
          line = word
          used = ww
          next
        end
        # A word wider than the column: as much of it as fits per line.
        word.each_grapheme do |g|
          gw = Unicode.width(g)
          if used + gw > width && used > 0
            lines << line
            line = ""
            used = 0
          end
          line += g.to_s
          used += gw
        end
      end
      lines << line unless line.empty?
      lines.empty? ? [""] : lines
    end

    # `#build`'s core with the format objects supplied. The editing ops pass the
    # live table's own block format (identity matters) and border colors rather
    # than fresh ones. *width* is the table's own width limit, bars included
    # (`.available_width`), or nil for natural widths.
    protected def self.build_blocks(header : Array(String), body : Array(Array(String)), alignments : Array(Tput::AlignFlag)?, cols : Int32, bf : TextBlockFormat, border_fmt : TextCharFormat, width : Int32? = nil) : Array(TextBlock)
      # A v_char inside a cell renders indistinguishably from a column boundary,
      # so grid recovery (`split_data_row`) would read it as an extra cell. Map
      # it to an ASCII '|', which recovery never splits on and the markdown
      # exporter escapes. This is the one sanitize choke point: every path into
      # the table — build/gfm/HTML import and the editing ops via
      # `rebuild_content` — funnels through here, so content is normalized once.
      header = header.map { |c| sanitize_cell(c, '|') }
      body = body.map { |row| row.map { |c| sanitize_cell(c, '|') } }

      widths = column_widths([header] + body, cols, width)

      tier = Glyphs::Tier::Unicode
      h = Glyphs[Glyphs::Role::LineHorizontal, tier]
      blocks = [] of TextBlock
      blocks << border_block(widths, Glyphs[Glyphs::Role::BorderLineTL, tier], Glyphs[Glyphs::Role::JunctionTeeTop, tier], Glyphs[Glyphs::Role::BorderLineTR, tier], h, border_fmt, bf)
      blocks << data_block(header, widths, alignments, bold: true, border_fmt: border_fmt, bf: bf)
      blocks << border_block(widths, Glyphs[Glyphs::Role::JunctionTeeLeft, tier], Glyphs[Glyphs::Role::JunctionCross, tier], Glyphs[Glyphs::Role::JunctionTeeRight, tier], h, border_fmt, bf)
      body.each do |row|
        blocks << data_block(row, widths, alignments, bold: false, border_fmt: border_fmt, bf: bf)
      end
      blocks << border_block(widths, Glyphs[Glyphs::Role::BorderLineBL, tier], Glyphs[Glyphs::Role::JunctionTeeBottom, tier], Glyphs[Glyphs::Role::BorderLineBR, tier], h, border_fmt, bf)
      blocks
    end

    # Splits a `| a | b |` GFM row into trimmed cells (outer pipes
    # optional). A backslash-escaped `\|` is a literal pipe inside its
    # cell, not a boundary (the markdown exporter writes them). A cell's
    # interior whitespace collapses to single spaces, as it does in a
    # paragraph (the padding that aligns a source table's columns is not
    # content).
    protected def self.split_gfm_row(row : String) : Array(String)
      row = row.strip
      cells = [] of String
      cur = String::Builder.new
      chars = row.chars
      i = 0
      while i < chars.size
        c = chars[i]
        if c == '\\' && chars[i + 1]? == '|'
          cur << '|'
          i += 2
        elsif c == '|'
          cells << cur.to_s
          cur = String::Builder.new
          i += 1
        else
          cur << c
          i += 1
        end
      end
      cells << cur.to_s
      # Outer pipes contribute empty edge cells; drop them.
      cells.shift if row.starts_with?('|') && !cells.empty?
      cells.pop if cells.size > 1 && row.ends_with?('|') && cells.last.empty?
      cells.map(&.strip.gsub(/[ \t]+/, ' '))
    end

    protected def self.gfm_align(spec : String) : Tput::AlignFlag
      left = spec.starts_with?(':')
      right = spec.ends_with?(':')
      return Tput::AlignFlag::HCenter if left && right
      return Tput::AlignFlag::Right if right
      Tput::AlignFlag::Left
    end

    # The GFM delimiter cell for an alignment.
    protected def self.gfm_delimiter(a : Tput::AlignFlag?) : String
      case a
      when Nil        then "---"
      when .h_center? then ":---:"
      when .right?    then "---:"
      else                 "---"
      end
    end

    private def self.border_block(widths, l : Char, mid : Char, r : Char, h : Char, border_fmt, bf) : TextBlock
      text = String.build do |io|
        io << l
        widths.each_with_index do |w, i|
          io << h.to_s * (w + 2)
          io << (i == widths.size - 1 ? r : mid)
        end
      end
      TextBlock.new([TextFragment.new(text, border_fmt)], bf)
    end

    # One data row's block: its cells wrapped to their column *widths*,
    # one display line after another (see the class docs), each line's
    # pieces aligned on their own. A wrapped row whose cells would not join
    # back from their pieces is remembered on the table format.
    private def self.data_block(cells, widths, alignments, bold : Bool, border_fmt, bf) : TextBlock
      v = v_char.to_s
      cell_fmt = bold ? TextCharFormat.new(bold: true) : TextCharFormat.default
      wrapped = widths.map_with_index { |w, i| wrap_cell(cells[i]? || "", w) }
      height = wrapped.max_of?(&.size) || 1
      frags = [] of TextFragment
      height.times do |line|
        frags << TextFragment.new(v, border_fmt)
        widths.each_with_index do |w, i|
          a = alignments.try(&.[i]?)
          frags << TextFragment.new(" #{Unicode.pad(wrapped[i][line]? || "", w, a)} ", cell_fmt)
          frags << TextFragment.new(v, border_fmt)
        end
      end
      block = TextBlock.new(frags, bf)
      if height > 1 && (tf = bf.table_format)
        text = block.text
        exact = Array.new(widths.size) { |i| (cells[i]? || "").strip(' ') }
        # A rendering that reads back as it looks forgets what it was
        # remembered for: the same lines can be a word broken mid-way or
        # the words of a space typed at that break, and the cells they
        # stand for now are these.
        if split_data_row(text) == exact
          tf.wrapped_cells.delete(text)
        else
          tf.wrapped_cells[text] = exact
        end
      end
      block
    end

    # *run* — one table's blocks, top border to bottom — rendered afresh for
    # *text_width* (`TextDocument#text_width`), from the grid it shows: the
    # new blocks, whose fragments are what *run*'s should become, or nil
    # when they already are, or when *run* is not a whole table.
    protected def self.rerender(run : Array(TextBlock), text_width : Int32?) : Array(TextBlock)?
      first = run.first? || return
      tf = first.block_format.table_format || return
      return if data_row?(first.text) || data_row?(run.last.text)
      data = run.select { |b| data_row?(b.text) }
      return if data.empty?
      rows = data.map { |b| split_data_row(b.text, tf) }
      fresh = build_blocks(rows[0], rows[1..], tf.alignments, tf.columns, first.block_format,
        border_char_format(first), available_width(text_width, first.block_format))
      return unless fresh.size == run.size
      return if fresh.each_with_index.all? { |b, k| b.text == run[k].text }
      fresh
    end

    # Re-renders, in place, every whole table among detached *blocks* that
    # does not fit *text_width* as rendered — what an import or an insertion
    # does before its blocks join a document of that width. Only the
    # fragments change: the blocks, their formats and source lines stay.
    protected def self.fit_blocks(blocks : Array(TextBlock), text_width : Int32?) : Bool
      changed = false
      each_run(blocks) do |first, last|
        if fresh = rerender(blocks[first..last], text_width)
          fresh.each_with_index { |b, k| blocks[first + k].replace_fragments(b.fragments) }
          changed = true
        end
      end
      changed
    end

    # Yields the `{first, last}` indexes of each run of consecutive *blocks*
    # sharing one table format — each table.
    protected def self.each_run(blocks : Indexable(TextBlock), & : Int32, Int32 ->) : Nil
      i = 0
      while i < blocks.size
        tf = blocks[i].block_format.table_format
        unless tf
          i += 1
          next
        end
        j = i
        while j + 1 < blocks.size && blocks[j + 1].block_format.table_format.same?(tf)
          j += 1
        end
        yield i, j
        i = j + 1
      end
    end
  end

  class TextDocument
    # The width, in cells, the document lays out to (Qt
    # `QTextDocument::textWidth`), or nil for none. A view that wraps its
    # text sets it to its wrap width (`Widget::TextEdit` does, on each
    # change of its width; nil when it does not wrap).
    #
    # It is the tables it concerns: the pre-rendered grids are fitted to it
    # (`TextTable.column_widths`), so a new width re-renders every table
    # whose rendering differs at it — its cells wrapping or unwrapping. That
    # is layout, not an edit: no undo step is recorded and `#modified?`
    # stays as it was. The re-rendering is announced as an
    # `Event::ContentsChanged` per table (`ChangeKind::Edit`, the table's
    # old and new lengths), and a position inside the table follows its
    # cell: a cursor in a cell stays at the same offset of that cell's text,
    # one at a row's start or end stays there, one on a border row at the
    # same offset (clamped) — `TextCursor`s and, through
    # `#position_after_change`, a view's caret. Positions after the table
    # shift. The undo history stays: the stack keeps the re-renderings and
    # replays each command at the width it was made at, the tables then
    # fitted to the current width again (`TextUndoStack#reflowed`); only
    # inside an edit block (`#edit`), whose commands would straddle the
    # change, is it dropped. An import (`#set_markdown`, `#set_html`,
    # `#append_markdown`, …) and an insertion render their tables at the
    # current width.
    getter text_width : Int32?

    # :ditto:
    def text_width=(width : Int32?) : Int32?
      return width if width == @text_width
      @text_width = width
      reflows = fit_tables(width)
      return width if reflows.empty?
      if undo_stack.in_macro?
        undo_stack.drop_history
      else
        undo_stack.reflowed(reflows)
      end
      width
    end

    # One table's re-rendering to a new `#text_width`: the blocks from index
    # *first* on, with the fragments they had (*old*) and were given
    # (*new*) — what `TextUndoStack` plays back and forth to replay a
    # command at the width it was made at.
    record TableReflow, first : Int32, old : Array(TextBlock), new : Array(TextBlock)

    # Re-renders every table whose rendering differs at *width*, returning
    # the re-renderings.
    protected def fit_tables(width : Int32?) : Array(TableReflow)
      reflows = [] of TableReflow
      bs = blocks_mut
      TextTable.each_run(bs) do |first, last|
        run = bs[first..last]
        if fresh = TextTable.rerender(run, width)
          old = run.map(&.clone)
          raw_rerender_block_run(first, fresh)
          reflows << TableReflow.new(first, old, fresh)
        end
      end
      reflows
    end

    # Plays *reflows* forward, or *backward* (from the last, each table
    # given back its old fragments), returning false — and stopping — at a
    # table not found as the re-rendering left it (or found it).
    protected def replay_reflows(reflows : Array(TableReflow), backward : Bool) : Bool
      bs = blocks_mut
      (backward ? reflows.reverse : reflows).each do |r|
        from, to = backward ? {r.new, r.old} : {r.old, r.new}
        return false unless r.first + from.size <= bs.size
        return false unless from.each_with_index.all? { |b, k| bs[r.first + k].text == b.text }
        raw_rerender_block_run(r.first, to)
      end
      true
    end

    # Records, as an undo step, that *format* now reads its row at *pos*,
    # rendered *text*, as *now* rather than *was* (`TextTableFormat#wrapped_cells`,
    # nil for its plain reading): the cells changed though the text did not.
    protected def change_wrapped_cells(pos : Int32, format : TextTableFormat, text : String, was : Array(String)?, now : Array(String)?) : Nil
      raw_set_wrapped_cells(pos, format, text, now)
      record_undo TextUndoStack::WrappedCellsCommand.new(pos, format, text, was, now)
    end

    # Makes *format* read its row at *pos*, rendered *text*, as *cells* (nil
    # for its plain reading), announced as a format change of the row: its
    # cells are new, its text and positions are not.
    protected def raw_set_wrapped_cells(pos : Int32, format : TextTableFormat, text : String, cells : Array(String)?) : Nil
      if cells
        format.wrapped_cells[text] = cells.dup
      else
        format.wrapped_cells.delete(text)
      end
      finish_edit(pos, text.size, text.size, kind: :format)
    end

    # Gives the blocks from index *first* on the fragments of *fresh*, a
    # table's re-rendering (`TextTable.rerender`), as one change with no
    # undo command (the `raw_*` contract). The blocks themselves stay — their
    # formats, source lines and identity — and positions in them move to the
    # same cell (see `#text_width`).
    protected def raw_rerender_block_run(first : Int32, fresh : Array(TextBlock)) : Nil
      bs = blocks_mut
      pos = block_position(first)
      old_texts = Array.new(fresh.size) { |k| bs[first + k].text }
      removed = old_texts.sum(&.size) + fresh.size - 1
      added = fresh.sum(&.size) + fresh.size - 1
      tf = bs[first].block_format.table_format
      new_texts = fresh.map(&.text)
      remap = ->(p : Int32) do
        if p < pos
          p
        elsif p > pos + removed
          p - removed + added
        else
          off = p - pos
          k = 0
          start = pos
          while k < old_texts.size - 1 && off > old_texts[k].size
            off -= old_texts[k].size + 1
            start += new_texts[k].size + 1
            k += 1
          end
          start + TextTable.follow_offset(old_texts[k], new_texts[k], off, tf)
        end
      end
      fresh.each_with_index { |b, k| bs[first + k].replace_fragments(b.fragments) }
      finish_edit(pos, removed, added, remap: remap)
    end
  end

  class TextTable
    # Where block offset *off* of a table row rendered as *old* lands in
    # its re-rendering *new*: the same offset in the same cell's text for a
    # data row, the start or end of the row for its start or end, the same
    # offset (clamped) on a border row.
    protected def self.follow_offset(old : String, new : String, off : Int32, format : TextTableFormat?) : Int32
      return 0 if off <= 0
      return new.size if off >= old.size
      return off.clamp(0, new.size) unless data_row?(old) && data_row?(new)
      col = column_at(old, off) || return off.clamp(0, new.size)
      cell_off = cell_offset_in(old, col, off, format) || 0
      cell_block_offset(new, col, cell_off, format) || off.clamp(0, new.size)
    end
  end

  class TextCursor
    # Inserts an empty table of *rows* data rows (the first is the bold
    # header row — the terminal rendering has no headerless grid) by
    # *columns* at the cursor, returning its `TextTable` view (Qt
    # `insertTable`; here the grid is pre-rendered box drawing — see
    # `TextTable`). One undo step; mirrors `#insert_list`/`#insert_toc`.
    # Fill cells afterwards through the view (`TextTable#set_cell_text`), or
    # use the content overload below.
    def insert_table(rows : Int32, columns : Int32) : TextTable
      rows = Math.max(rows, 1)
      columns = Math.max(columns, 1)
      empty_row = Array.new(columns, "")
      insert_table(empty_row.dup, Array.new(rows - 1) { empty_row.dup })
    end

    # :ditto: — with content: *header* cells (their count fixes the column
    # count) and *body* rows.
    def insert_table(header : Array(String), body : Array(Array(String)) = [] of Array(String)) : TextTable
      built = TextTable.build(header, body, text_width: @document.text_width)
      tf = built.first.block_format.table_format ||
           raise "TextTable.build produced blocks without a table format"

      @document.edit do
        # Mid-block, break first so the table starts on a row of its own (the
        # `#insert_toc` convention); an empty block at its start is free real
        # estate — the table's last block becomes it — otherwise the run
        # needs its own trailing separator.
        insert_block unless at_block_start?
        text = built.join('\n', &.text)
        text += '\n' unless block.empty?
        start = @position
        # Insert the text first and stamp formats after: `insert_text` splits
        # on `'\n'` into blocks the same way typing would, which sidesteps
        # the block-format adoption rules a multi-block fragment insertion
        # carries (again the `#insert_toc` recipe).
        @document.insert_text(start, text)
        pos = start
        built.each do |b|
          @document.apply_block_format(pos, pos, b.block_format)
          off = 0
          b.fragments.each do |f|
            @document.apply_char_format(pos + off, pos + off + f.size, f.format)
            off += f.size
          end
          pos += b.size + 1
        end
      end
      TextTable.new(@document, tf)
    end

    # The table the cursor's block belongs to, as a fresh view — or nil (Qt
    # `currentTable`).
    def current_table : TextTable?
      block.block_format.table_format.try { |tf| TextTable.new(@document, tf) }
    end
  end
end
