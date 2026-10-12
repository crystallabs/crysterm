require "./spec_helper"

include Crysterm

# Tables fitted to the document's text width (`TextDocument#text_width`,
# Qt's `textWidth`): columns shrink and cells wrap, a wrapped data row stays
# one block whose text is its display lines one after another, the grid and
# the exporters read it back, a width change reflows without an undo step,
# `Widget::TextEdit` sets the width it wraps to, and cell editing works on
# wrapped cells.

private GFM = <<-MD
  | Key | What it does |
  | --- | --- |
  | F1 | Shows the description of the highlighted menu entry beside it until the next key |
  | F5 | Cycles the mouse modes |
  MD

private def width_of(line : String) : Int32
  Crysterm::Unicode.display_width(line)
end

# Every display line of every block of the document's tables, by block.
private def table_lines(doc : TextDocument) : Array(Array(String))
  doc.blocks.select(&.block_format.table_format).map { |b| TextTable.display_lines(b.text) }
end

# The distinct display widths of those lines.
private def table_widths(doc : TextDocument) : Array(Int32)
  widths = table_lines(doc).flatten.map { |l| width_of(l) }
  widths.uniq!
  widths
end

private def table_of(doc : TextDocument) : TextTable
  TextTable.new(doc, doc.blocks.find!(&.block_format.table_format).block_format.table_format.not_nil!)
end

private def table_te(s, width = 30, md = GFM)
  te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: width, height: 20
  te.set_markdown md
  s.repaint
  {te, table_of(te.document)}
end

private def key(te, k : ::Tput::Key)
  te._listener Crysterm::Event::KeyPress.new '\0', k
end

private def type(te, text : String)
  text.each_char { |c| te._listener Crysterm::Event::KeyPress.new(c) }
end

describe TextTable do
  describe ".column_widths" do
    it "keeps the natural widths without a width or when they fit" do
      rows = [["a", "bb"], ["ccc", "d"]]
      TextTable.column_widths(rows, 2, nil).should eq [3, 2]
      TextTable.column_widths(rows, 2, 12).should eq [3, 2]
    end

    it "keeps a narrow column and gives the wide one the rest, not below its longest word" do
      rows = [["Key", "one two three four five six seven eight nine ten"]]
      widths = TextTable.column_widths(rows, 2, 30)
      widths[0].should eq 3
      (widths.sum + 3 * 2 + 1).should eq 30
      rows = [["a", "xxxxxxxxxxxx yy"]]
      TextTable.column_widths(rows, 2, 20).should eq [1, 12]
    end

    it "breaks words when even the longest ones do not fit" do
      rows = [["abcdefgh", "ijklmnop"]]
      widths = TextTable.column_widths(rows, 2, 13)
      (widths.sum + 7).should eq 13
      widths.all?(&.>=(1)).should be_true
    end

    it "shares the space in proportion between wide columns" do
      rows = [["a " * 20, "b " * 10]]
      w = TextTable.column_widths(rows, 2, 37)
      w.sum.should eq 30
      w[0].should be > w[1]
    end
  end

  describe ".build with a text width" do
    it "renders every line of every block at the table's width" do
      blocks = TextTable.build(["Key", "What it does"], [["F1", "Shows the description of the highlighted entry"]], text_width: 24)
      widths = blocks.flat_map { |b| TextTable.display_lines(b.text).map { |l| width_of(l) } }
      widths.uniq.should eq [24]
      blocks.size.should eq 5 # one block per row, however many lines
      TextTable.display_lines(blocks[3].text).size.should be > 1
      TextTable.display_lines(blocks[0].text).size.should eq 1
    end

    it "keeps the header bold on all its lines and aligns each line" do
      blocks = TextTable.build(["Long heading words", "B"], [["x", "y"]], [Tput::AlignFlag::Right, Tput::AlignFlag::Left], text_width: 16)
      header = blocks[1]
      TextTable.display_lines(header.text).size.should be > 1
      header.fragments.reject(&.format.rule?).all?(&.format.bold?).should be_true
      lines = TextTable.display_lines(blocks[3].text)
      lines[0].should match(/│ +x │/)
    end

    it "wraps wide characters by their display width" do
      blocks = TextTable.build(["名前", "説明"], [["漢字", "日本語の説明文です"]], text_width: 16)
      TextTable.display_lines(blocks[3].text).each { |l| width_of(l).should be <= 16 }
      TextTable.split_data_row(blocks[3].text, blocks[3].block_format.table_format).should eq ["漢字", "日本語の説明文です"]
    end
  end

  describe ".split_data_row on a wrapped row" do
    it "joins each column's pieces with single spaces" do
      blocks = TextTable.build(["A", "B"], [["one two three four", "x"]], text_width: 14)
      TextTable.split_data_row(blocks[3].text).should eq ["one two three four", "x"]
    end

    it "gives a word broken in the middle back exactly through the table format" do
      blocks = TextTable.build(["A", "B"], [["abcdefghijkl", "x"]], text_width: 12)
      row = blocks[3].text
      TextTable.display_lines(row).size.should be > 1
      TextTable.split_data_row(row, blocks[3].block_format.table_format).should eq ["abcdefghijkl", "x"]
      # Without the table it is read as it looks: a space at each break.
      TextTable.split_data_row(row)[0].should_not eq "abcdefghijkl"
    end
  end
end

describe TextDocument do
  describe "#text_width" do
    it "reflows the tables without an undo step or a modification" do
      doc = TextDocument.new
      doc.set_markdown GFM
      natural = doc.to_markdown
      changes = 0
      doc.on(Crysterm::Event::ContentsChanged) { changes += 1 }
      doc.text_width = 30
      changes.should eq 1
      table_widths(doc).should eq [30]
      doc.modified?.should be_false
      doc.undo_available?.should be_false
      doc.to_markdown.should eq natural
      # The same width again does nothing.
      doc.text_width = 30
      changes.should eq 1
      # Back to no limit: the natural rendering.
      doc.text_width = nil
      doc.to_markdown.should eq natural
      table_lines(doc).all? { |ls| ls.size == 1 }.should be_true
    end

    it "keeps rows as blocks, with their source lines" do
      doc = TextDocument.new
      doc.set_markdown GFM
      lines = doc.blocks.map(&.source_line)
      count = doc.block_count
      doc.text_width = 30
      doc.block_count.should eq count
      doc.blocks.map(&.source_line).should eq lines
      doc.block_from_source_line(3).should eq 3
    end

    it "round-trips a word broken in the middle through any widths" do
      doc = TextDocument.new
      doc.set_markdown "| A | B |\n| --- | --- |\n| https://example.com/a/very/long/path | x |"
      natural = doc.to_markdown
      [20, 14, 11, 40, nil].each do |w|
        doc.text_width = w
        doc.to_markdown.should eq natural
      end
    end

    it "keeps a cursor in the same cell, and shifts one after the table" do
      doc = TextDocument.new
      doc.set_markdown GFM + "\n\nafter"
      tbl = table_of(doc)
      inside = doc.cursor(tbl.cell_position(2, 1, 20).not_nil!)
      after = doc.cursor(doc.size)
      start = doc.cursor(doc.blocks[3].position)
      doc.text_width = 30
      tbl.cell_at(inside.position).should eq({2, 1})
      tbl.cell_offset(2, 1, inside.position).should eq 20
      after.position.should eq doc.size
      start.position.should eq doc.blocks[3].position
    end

    it "keeps the modified state and drops an undo history the reflow invalidates" do
      doc = TextDocument.new
      doc.set_markdown GFM + "\n\npara"
      doc.cursor(doc.size).insert_text("!")
      doc.modified?.should be_true
      doc.text_width = 30
      doc.modified?.should be_true
      doc.undo_available?.should be_false
    end

    it "renders an import at the current width, a streamed one too" do
      doc = TextDocument.new
      doc.text_width = 30
      doc.set_markdown GFM
      table_widths(doc).should eq [30]
      doc.set_html "<table><tr><th>A</th><th>B</th></tr><tr><td>#{"word " * 12}</td><td>y</td></tr></table>"
      table_widths(doc).should eq [30]

      streamed = TextDocument.new
      streamed.text_width = 30
      streamed.append_markdown "intro\n\n"
      GFM.each_line(chomp: false) { |l| streamed.append_markdown l }
      streamed.append_markdown "\n\nend\n"
      streamed.flush_markdown
      table_widths(streamed).should eq [30]
    end

    it "fits a table in a quote within the quote's bars" do
      doc = TextDocument.new
      doc.set_markdown GFM.lines.map { |l| "> #{l}" }.join('\n')
      doc.text_width = 30
      table_widths(doc).should eq [28]
    end

    it "copies a wrapped row as plain text line by line, as it reads" do
      doc = TextDocument.new
      doc.set_markdown GFM
      doc.text_width = 30
      text = doc.copy_fragment(0, doc.size).to_plain_text
      text.lines.map { |l| width_of(l) }.uniq!.should eq [30]
      text.lines.size.should be > doc.block_count
    end

    it "inserts a table at the current width" do
      doc = TextDocument.new
      doc.text_width = 20
      tbl = doc.cursor.insert_table(["Header", "Another header"], [["a b c d e f g", "x"]])
      table_widths(doc).should eq [20]
      tbl.cell_text(0, 1).should eq "Another header"
    end
  end
end

describe Widget::TextEdit do
  describe "tables at the view's width" do
    it "sets the document's text width to its wrap width, nil without wrapping" do
      s = headless_screen(60, 24, default_quit_keys: true)
      te, _ = table_te s, 30
      te.document.text_width.should_not be_nil
      te.document.text_width.not_nil!.should be <= 30
      te.wrap_content = false
      s.repaint
      te.document.text_width.should be_nil
      table_lines(te.document).all? { |ls| ls.size == 1 }.should be_true
    end

    it "lays a wrapped row out as one display row per line of the grid" do
      s = headless_screen(60, 24, default_quit_keys: true)
      te, _ = table_te s, 30
      w = te.document.text_width.not_nil!
      rows = te.wrapped_lines.lines.reject(&.empty?)
      grid = rows.select(&.starts_with?(/[┌├└│]/))
      grid.size.should be > 6
      grid.each { |r| width_of(r.rstrip).should eq w }
      grid.each(&.should(match(/[┐┤┘│]\s*\z/)))
    end

    it "reflows when the view is resized, the caret staying in its cell" do
      s = headless_screen(130, 24, default_quit_keys: true)
      te, tbl = table_te s, 120
      te.cursor_pos = tbl.cell_position(1, 1, 30).not_nil!
      table_lines(te.document).all? { |ls| ls.size == 1 }.should be_true
      te.width = 30
      s.repaint
      table_lines(te.document).any? { |ls| ls.size > 1 }.should be_true
      tbl.cell_at(te.cursor_pos).should eq({1, 1})
      tbl.cell_offset(1, 1, te.cursor_pos).should eq 30
    end

    it "maps any line of a wrapped cell to its cell" do
      s = headless_screen(60, 24, default_quit_keys: true)
      _, tbl = table_te s, 30
      row = tbl.row_block(1).not_nil!
      lines = TextTable.display_lines(row.text)
      lines.size.should be > 1
      second = row.position + lines[0].size + lines[1].index!(/[a-z]/)
      tbl.cell_at(second).should eq({1, 1})
    end

    it "types at the end of a wrapped cell" do
      s = headless_screen(60, 24, default_quit_keys: true)
      te, tbl = table_te s, 30
      text = tbl.cell_text(1, 1).not_nil!
      te.cursor_pos = tbl.cell_position(1, 1, Int32::MAX).not_nil!
      type te, "!"
      tbl.cell_text(1, 1).should eq text + "!"
      tbl.cell_offset(1, 1, te.cursor_pos).should eq text.size + 1
      table_widths(te.document).size.should eq 1
    end

    it "types in the middle of a wrapped cell's later line" do
      s = headless_screen(60, 24, default_quit_keys: true)
      te, tbl = table_te s, 30
      text = tbl.cell_text(1, 1).not_nil!
      at = text.index!("next")
      te.cursor_pos = tbl.cell_position(1, 1, at).not_nil!
      type te, "X"
      tbl.cell_text(1, 1).should eq text.insert(at, 'X')
      tbl.cell_offset(1, 1, te.cursor_pos).should eq at + 1
    end

    it "Backspace removes the character before the caret in a wrapped cell" do
      s = headless_screen(60, 24, default_quit_keys: true)
      te, tbl = table_te s, 30
      text = tbl.cell_text(1, 1).not_nil!
      te.cursor_pos = tbl.cell_position(1, 1, text.size).not_nil!
      key te, ::Tput::Key::Backspace
      tbl.cell_text(1, 1).should eq text[0...-1]
      tbl.cell_offset(1, 1, te.cursor_pos).should eq text.size - 1
      # At the cell's start it is absorbed.
      te.cursor_pos = tbl.cell_position(1, 1, 0).not_nil!
      key te, ::Tput::Key::Backspace
      tbl.cell_text(1, 1).should eq text[0...-1]
    end

    it "Tab moves between cells of wrapped rows" do
      s = headless_screen(60, 24, default_quit_keys: true)
      te, tbl = table_te s, 30
      te.cursor_pos = tbl.cell_position(1, 0, 0).not_nil!
      key te, ::Tput::Key::Tab
      tbl.cell_at(te.cursor_pos).should eq({1, 1})
      tbl.cell_offset(1, 1, te.cursor_pos).should eq tbl.cell_text(1, 1).not_nil!.size
      key te, ::Tput::Key::Tab
      tbl.cell_at(te.cursor_pos).should eq({2, 0})
      key te, ::Tput::Key::ShiftTab
      tbl.cell_at(te.cursor_pos).should eq({1, 1})
    end

    it "undoes a cell edit in a wrapped table" do
      s = headless_screen(60, 24, default_quit_keys: true)
      te, tbl = table_te s, 30
      before = te.document.to_plain_text
      te.cursor_pos = tbl.cell_position(1, 1, 5).not_nil!
      type te, "Z"
      te.document.undo
      te.document.to_plain_text.should eq before
    end
  end
end
