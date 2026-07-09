module Crysterm
  # A table of a document (Qt `QTextTable`), **read-only, pre-rendered** in
  # this first Phase-4 cut: the table exists in the document as ordinary
  # blocks holding its box-drawing rendering — border rows plus one
  # column-padded data row per table row — every block referencing the same
  # `TextTableFormat` instance (identity = table identity, the `TextList`
  # convention). That keeps the display-row ↔ document-position geometry of
  # `Widget::TextEdit` exact with zero special cases: caret, selection and
  # copy treat a table as the text it looks like.
  #
  # This class is the structured *view* over those blocks: `#rows`/
  # `#columns`/`#cell_text` recover the grid, and the interchange exporters
  # use it to round-trip GFM/HTML tables. Cell *editing* and per-cell
  # cursors (Qt's full `QTextTable`) are the planned follow-up and would
  # re-render the padding on change.
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
      cols = header.size
      tf = TextTableFormat.new(columns: cols, alignments: alignments)
      bf = TextBlockFormat.new(table_format: tf, non_breakable: true)
      border_fmt = TextCharFormat.new(fg: theme.rule_color)

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

    # Splits a `| a | b |` GFM row into trimmed cells (outer pipes optional).
    protected def self.split_gfm_row(row : String) : Array(String)
      row.strip.sub(/\A\|/, "").sub(/\|\z/, "").split('|').map(&.strip)
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
        frags << TextFragment.new(" #{pad_cell(cell, w, a)} ", cell_fmt)
        frags << TextFragment.new(v, border_fmt)
      end
      TextBlock.new(frags, bf)
    end

    private def self.pad_cell(cell : String, width : Int32, align : Tput::AlignFlag?) : String
      pad = width - Unicode.display_width(cell)
      return cell if pad <= 0
      case align
      when Nil        then cell + (" " * pad)
      when .h_center? then (" " * (pad // 2)) + cell + (" " * (pad - pad // 2))
      when .right?    then (" " * pad) + cell
      else                 cell + (" " * pad)
      end
    end
  end
end
