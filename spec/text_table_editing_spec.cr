require "./spec_helper"

include Crysterm

# `TextTable` editing (TEXTEDIT.md follow-up: editable tables + cell
# cursors). Pure model: cell location primitives (`cell_at`,
# `cell_text_range`, `cell_cursor`), cell rewriting with padding re-render,
# and row/column restructuring — each op one undo step through the
# document's editing API.

private GFM = "| Name | N |\n| --- | ---: |\n| ab | 1 |\n| c | 22 |"

private def table_doc
  doc = TextDocument.from_markdown(GFM)
  {doc, TextTable.new(doc, doc.blocks[0].block_format.table_format.not_nil!)}
end

describe Crysterm::TextTable do
  describe "cell cursors" do
    it "locates cell text ranges" do
      doc, tbl = table_doc
      r = tbl.cell_text_range(0, 0).not_nil!
      doc.plain_text(r.begin, r.end).should eq "Name"
      r = tbl.cell_text_range(1, 1).not_nil! # right-aligned "1"
      doc.plain_text(r.begin, r.end).should eq "1"
      tbl.cell_text_range(3, 0).should be_nil
      tbl.cell_text_range(0, 2).should be_nil
    end

    it "maps positions to cells and back" do
      doc, tbl = table_doc
      r = tbl.cell_text_range(2, 0).not_nil!
      tbl.cell_at(r.begin).should eq({2, 0})
      tbl.cell_at(r.end).should eq({2, 0})
      # A border-row position has no cell.
      tbl.cell_at(0).should be_nil
      c = tbl.cell_cursor(1, 1).not_nil!
      c.position.should eq tbl.cell_text_range(1, 1).not_nil!.begin
    end

    it "places a caret in an empty cell" do
      doc, tbl = table_doc
      tbl.set_cell_text(2, 0, "")
      r = tbl.cell_text_range(2, 0).not_nil!
      r.size.should eq 0
      tbl.cell_at(r.begin).should eq({2, 0})
    end
  end

  describe "set_cell_text" do
    it "rewrites a cell in place" do
      doc, tbl = table_doc
      tbl.set_cell_text(1, 0, "abcd").should be_true
      tbl.cell_text(1, 0).should eq "abcd"
      # Same width (column already fits 4: "Name") — padding intact.
      doc.blocks[3].text.should eq "│ abcd │  1 │"
    end

    it "re-renders padding and borders when the column widens" do
      doc, tbl = table_doc
      tbl.set_cell_text(1, 0, "wider-than-name")
      doc.blocks[0].text.should eq "┌─────────────────┬────┐"
      doc.blocks[1].text.should eq "│ Name            │  N │"
      doc.blocks[3].text.should eq "│ wider-than-name │  1 │"
      # Alignment survives.
      tbl.cell_text(1, 1).should eq "1"
      doc.blocks[3].text.ends_with?("│  1 │").should be_true
    end

    it "is one undo step" do
      doc, tbl = table_doc
      before = doc.to_plain_text
      tbl.set_cell_text(1, 0, "wider-than-name")
      doc.undo.should be_true
      doc.to_plain_text.should eq before
      doc.redo.should be_true
      tbl.cell_text(1, 0).should eq "wider-than-name"
    end

    it "sanitizes newlines and border glyphs" do
      doc, tbl = table_doc
      tbl.set_cell_text(1, 0, "a\nb│c")
      tbl.cell_text(1, 0).should eq "a b c"
      doc.block_count.should eq 6
    end
  end

  describe "row operations" do
    it "inserts a blank row" do
      doc, tbl = table_doc
      tbl.insert_row(1).should be_true
      tbl.rows.should eq 4
      tbl.cell_text(1, 0).should eq ""
      tbl.cell_text(2, 0).should eq "ab"
      doc.block_count.should eq 7
      # Bottom border still closes the box.
      doc.blocks[6].text.starts_with?("└").should be_true
    end

    it "appends a row at the end" do
      doc, tbl = table_doc
      tbl.insert_row(tbl.rows, ["x", "y"]).should be_true
      tbl.cell_text(3, 0).should eq "x"
      tbl.cell_text(3, 1).should eq "y"
    end

    it "removes a row (header protected) as one undo step" do
      doc, tbl = table_doc
      before = doc.to_plain_text
      tbl.remove_row(0).should be_false
      tbl.remove_row(1).should be_true
      tbl.rows.should eq 2
      tbl.cell_text(1, 0).should eq "c"
      doc.block_count.should eq 5
      doc.undo.should be_true
      doc.to_plain_text.should eq before
    end
  end

  describe "column operations" do
    it "inserts a column, moving the table to a fresh format" do
      doc, tbl = table_doc
      old_tf = tbl.format
      tbl.insert_column(1, "Mid").should be_true
      tbl.columns.should eq 3
      tbl.format.same?(old_tf).should be_false
      doc.blocks[1].block_format.table_format.not_nil!.same?(tbl.format).should be_true
      tbl.cell_text(0, 1).should eq "Mid"
      tbl.cell_text(0, 2).should eq "N"
      tbl.cell_text(1, 2).should eq "1"
      # The right-alignment moved with its column.
      tbl.format.alignments.not_nil![2].right?.should be_true
    end

    it "removes a column" do
      doc, tbl = table_doc
      tbl.remove_column(1).should be_true
      tbl.columns.should eq 1
      tbl.cell_text(1, 0).should eq "ab"
      doc.blocks[1].text.should eq "│ Name │"
      # The last column is protected.
      tbl.remove_column(0).should be_false
    end
  end

  it "keeps exporting valid GFM after edits" do
    doc, tbl = table_doc
    tbl.set_cell_text(1, 0, "edited")
    tbl.insert_row(3, ["d", "3"])
    md = doc.to_markdown
    md.should contain "| edited | 1 |"
    md.should contain "| d | 3 |"
    doc2 = TextDocument.from_markdown(md)
    tbl2 = TextTable.new(doc2, doc2.blocks[0].block_format.table_format.not_nil!)
    tbl2.rows.should eq 4
    tbl2.cell_text(2, 1).should eq "22"
    tbl2.cell_text(3, 1).should eq "3"
  end
end
