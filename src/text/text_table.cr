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
  # The table is also **editable** (the Phase-4 follow-up): `#cell_at` /
  # `#cell_text_range` / `#cell_cursor` locate cells by document position
  # (the per-cell-cursor primitives `Widget::TextEdit`'s in-table editing
  # uses), `#set_cell_text` rewrites one cell, and `#insert_row` /
  # `#remove_row` / `#insert_column` / `#remove_column` restructure the grid
  # — each op re-renders the padding/borders through the document's undoable
  # editing API as ONE undo step. Column ops move the table to a fresh
  # `TextTableFormat` instance (the column count is part of the format);
  # this view follows it, but other views over the old instance go empty and
  # an undo restores the old instance — re-derive views after undo, as with
  # `TextList#format=`.
  #
  # Build one from a grid via `TextTable.build` (importers do), then insert
  # the returned blocks into a document.
  class TextTable < TextBlockGroup
    getter format : TextTableFormat

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
      data_blocks[row]?
    end

    # The trimmed text of cell (*row*, *column*), or nil when out of range.
    def cell_text(row : Int32, column : Int32) : String?
      b = row_block(row) || return nil
      TextTable.split_data_row(b.text)[column]?
    end

    # === Cell cursors / editing (the QTextTable follow-up) ===

    # The `{row, column}` of the cell whose rendered segment contains
    # document position *pos*, or nil when *pos* is not on one of this
    # table's data rows (border rows have no cells). A position on a border
    # glyph snaps to the cell left of it.
    def cell_at(pos : Int32) : {Int32, Int32}?
      bi, off = document.block_at(pos)
      b = document.blocks[bi]? || return nil
      return nil unless member?(b) && TextTable.data_row?(b.text)
      row = nil
      data_row_indexed.each_with_index do |(i, _), r|
        if i == bi
          row = r
          break
        end
      end
      return nil unless row
      bars = bar_positions(b.text)
      return nil if bars.size < 2
      col = (bars.count { |bp| bp < off } - 1).clamp(0, bars.size - 2)
      {row, col.clamp(0, columns - 1)}
    end

    # Document positions of cell (*row*, *column*)'s trimmed text, or nil
    # when out of range. Empty for an empty cell (a caret can still sit
    # there); alignment padding around the text is excluded.
    def cell_text_range(row : Int32, column : Int32) : Range(Int32, Int32)?
      entry = data_row_indexed[row]? || return nil
      bi, b = entry
      text = b.text
      bars = bar_positions(text)
      return nil unless column + 1 < bars.size
      inner_lo = bars[column] + 2     # past the bar and its pad space
      inner_hi = bars[column + 1] - 1 # exclusive; before the trailing pad
      return nil if inner_hi < inner_lo
      raw = text[inner_lo, inner_hi - inner_lo]
      lead = 0
      while lead < raw.size && raw[lead] == ' '
        lead += 1
      end
      bp = document.block_position(bi)
      # All-spaces cell: an empty range at the left inner edge.
      return (bp + inner_lo)...(bp + inner_lo) if lead == raw.size
      trail = 0
      while raw[raw.size - 1 - trail] == ' '
        trail += 1
      end
      (bp + inner_lo + lead)...(bp + inner_hi - trail)
    end

    # A cursor at the start of cell (*row*, *column*)'s text (Qt
    # `cellAt(...).firstCursorPosition()`), or nil when out of range.
    def cell_cursor(row : Int32, column : Int32) : TextCursor?
      r = cell_text_range(row, column) || return nil
      TextCursor.new(document, r.begin)
    end

    # Rewrites cell (*row*, *column*)'s text, re-rendering the column
    # padding (and borders when the column widens/narrows) — one undo step.
    # Newlines and border glyphs in *text* become spaces. Returns whether
    # the cell existed.
    def set_cell_text(row : Int32, column : Int32, text : String) : Bool
      return false unless row >= 0 && row < rows && column >= 0 && column < columns
      header, body = grid
      (row == 0 ? header : body[row - 1])[column] = sanitize_cell(text)
      rebuild_content(header, body)
      true
    end

    # Inserts a blank data row so it becomes 0-based data row *at* (clamped
    # to 1..rows — the header stays row 0), re-rendering the table (one undo
    # step). Qt `insertRows` analog.
    def insert_row(at : Int32, cells : Array(String)? = nil) : Bool
      at = at.clamp(1, rows)
      header, body = grid
      row = (cells || [] of String).map { |c| sanitize_cell(c) }
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
      header.insert(at, sanitize_cell(header_text))
      body.each(&.insert(at, ""))
      als = @format.alignments.try(&.dup)
      # A partial alignments array (fewer entries than columns — typical
      # after HTML import) would make `Array#insert(at, …)` raise IndexError
      # for `at > size`; pad to full width first so the insert lands in range
      # and the new column's alignment is positioned correctly (T4).
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
      texts = data_row_indexed.map { |(_, b)| TextTable.split_data_row(b.text) }
      header = texts.first? || [] of String
      {header, texts.size > 1 ? texts[1..] : [] of Array(String)}
    end

    # `{block index, block}` of each data row, in document order.
    private def data_row_indexed : Array({Int32, TextBlock})
      res = [] of {Int32, TextBlock}
      document.blocks.each_with_index do |b, i|
        res << {i, b} if member?(b) && TextTable.data_row?(b.text)
      end
      res
    end

    # Codepoint indexes of the border glyphs in a data row's text.
    private def bar_positions(text : String) : Array(Int32)
      v = TextTable.v_char
      bars = [] of Int32
      text.each_char_with_index { |c, i| bars << i if c == v }
      bars
    end

    # The char format of the borders (recovered from the top border row, so
    # a rebuild keeps the theme the table was imported with).
    private def border_char_format : TextCharFormat
      blocks.first?.try(&.fragments.first?.try(&.format)) || TextCharFormat.default
    end

    private def sanitize_cell(s : String) : String
      s = s.gsub('\n', ' ')
      s = s.gsub(TextTable.v_char, ' ') if s.includes?(TextTable.v_char)
      s
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
      base_bf = doc.blocks[first_bi].block_format
      bf = new_format ? base_bf.merge(TextBlockFormat.new(table_format: tf)) : base_bf
      fresh = TextTable.build_blocks(header, body, tf.alignments, tf.columns, bf, border_char_format)
      doc.begin_edit_block
      begin
        common = Math.min(old_count, fresh.size)
        (0...common).each do |k|
          bi = first_bi + k
          b = doc.blocks[bi]
          nb = fresh[k]
          next if b.text == nb.text
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
      ensure
        doc.end_edit_block
      end
    end

    private def data_blocks : Array(TextBlock)
      blocks.select { |b| TextTable.data_row?(b.text) }
    end

    # === Rendering / recovery helpers (module-level so importers/exporters
    # work on detached blocks) ===

    # The vertical border glyph the pre-rendered blocks use. Model-level
    # rendering is fixed to the Unicode tier, like `TextMarkdown.rule_text` —
    # importers run widget-independent.
    protected def self.v_char : Char
      Glyphs[Glyphs::Role::LineVertical, Glyphs::Tier::Unicode]
    end

    # Whether pre-rendered block text is a data row (vs. a border row).
    def self.data_row?(text : String) : Bool
      text.starts_with?(v_char)
    end

    # Splits a pre-rendered data row back into trimmed cell texts.
    def self.split_data_row(text : String) : Array(String)
      cells = text.split(v_char)
      cells.shift if cells.first?.try(&.blank?)
      cells.pop if cells.last?.try(&.blank?)
      cells.map(&.strip)
    end

    # Whether *text* is a GFM table: a `|` header row, then a delimiter row
    # of `-`/`:`/`|`/spaces containing at least one `-` (same detection as
    # `Widget::Markdown`, whose markd parser hands GFM tables through as a
    # plain paragraph).
    def self.gfm_table?(text : String) : Bool
      lines = text.lines
      return false if lines.size < 2
      lines[0].includes?('|') &&
        lines[1].matches?(/\A\s*\|?[\s:|-]*-[\s:|-]*\|?\s*\z/) &&
        lines[1].includes?('-')
    end

    # Builds the pre-rendered blocks for a GFM table text (see
    # `.gfm_table?`). Returns nil when *text* isn't one.
    def self.build_from_gfm(text : String, theme : TextTheme = TextTheme.default) : Array(TextBlock)?
      return nil unless gfm_table?(text)
      rows = text.lines.map(&.strip).reject(&.empty?)
      header = split_gfm_row(rows[0])
      alignments = split_gfm_row(rows[1]).map { |c| gfm_align(c) }
      body = rows[2..]?.try(&.map { |r| split_gfm_row(r) }) || [] of Array(String)
      return nil if header.empty?
      build(header, body, alignments, theme)
    end

    # Builds the pre-rendered blocks for a cell grid: top border, bold
    # *header* row, separator, *body* rows, bottom border — columns padded
    # to content width under the per-column *alignments*.
    def self.build(header : Array(String), body : Array(Array(String)), alignments : Array(Tput::AlignFlag)? = nil, theme : TextTheme = TextTheme.default) : Array(TextBlock)
      tf = TextTableFormat.new(columns: header.size, alignments: alignments)
      bf = TextBlockFormat.new(table_format: tf, non_breakable: true)
      build_blocks(header, body, alignments, header.size, bf, TextCharFormat.new(fg: theme.rule_color))
    end

    # `#build`'s core with the format objects supplied — shared with the
    # editing ops' `#rebuild_content`, which reuses the live table's block
    # format (identity!) and border colors instead of fresh ones.
    protected def self.build_blocks(header : Array(String), body : Array(Array(String)), alignments : Array(Tput::AlignFlag)?, cols : Int32, bf : TextBlockFormat, border_fmt : TextCharFormat) : Array(TextBlock)
      widths = Array.new(cols, 0)
      ([header] + body).each do |row|
        row.each_with_index do |cell, i|
          widths[i] = Math.max(widths[i], Unicode.display_width(cell)) if i < cols
        end
      end

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
    # cell, not a boundary (the markdown exporter writes them).
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
      # Outer pipes contribute empty edge cells; drop them like the
      # historical leading/trailing-pipe strip did.
      cells.shift if row.starts_with?('|') && !cells.empty?
      cells.pop if cells.size > 1 && row.ends_with?('|') && cells.last.empty?
      cells.map(&.strip)
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

    private def self.data_block(cells, widths, alignments, bold : Bool, border_fmt, bf) : TextBlock
      v = v_char.to_s
      cell_fmt = bold ? TextCharFormat.new(bold: true) : TextCharFormat.default
      frags = [] of TextFragment
      frags << TextFragment.new(v, border_fmt)
      widths.each_with_index do |w, i|
        cell = cells[i]? || ""
        a = alignments.try(&.[i]?)
        frags << TextFragment.new(" #{Unicode.pad(cell, w, a)} ", cell_fmt)
        frags << TextFragment.new(v, border_fmt)
      end
      TextBlock.new(frags, bf)
    end
  end
end
