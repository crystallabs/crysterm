require "./spec_helper"

include Crysterm

# Table-aware `TextCursor` movement: the `NextCell`/`PreviousCell`/
# `NextRow`/`PreviousRow` operations, and `Up`/`Down` treating table
# structure as transparent (border rows skipped, landings snapped into a
# cell).

# "above", a 2×3 table (header + 2 body rows), "below".
private def surrounded_table_doc
  doc = TextDocument.new("above")
  c = doc.cursor(doc.size)
  tbl = c.insert_table(["H1", "H2"], [["a", "b"], ["c", "d"]])
  tail = doc.cursor(doc.size)
  tail.insert_block(TextBlockFormat.new) # explicit: don't inherit the table's format
  tail.insert_text("below")
  {doc, tbl}
end

private def cell_start(tbl, row, col)
  tbl.cell_text_range(row, col).not_nil!.begin
end

describe Crysterm::TextCursor do
  describe "NextCell / PreviousCell" do
    it "moves to the start of the next cell's text within a row" do
      doc, tbl = surrounded_table_doc
      c = doc.cursor(cell_start(tbl, 0, 0))
      c.move_position(:next_cell).should be_true
      c.position.should eq cell_start(tbl, 0, 1)
    end

    it "wraps from a row's last cell to the next row's first" do
      doc, tbl = surrounded_table_doc
      c = doc.cursor(cell_start(tbl, 0, 1))
      c.move_position(:next_cell).should be_true
      c.position.should eq cell_start(tbl, 1, 0)
    end

    it "fails at the last cell, and outside a table" do
      doc, tbl = surrounded_table_doc
      c = doc.cursor(cell_start(tbl, 2, 1))
      c.move_position(:next_cell).should be_false
      c.position.should eq cell_start(tbl, 2, 1)
      out = doc.cursor(0)
      out.move_position(:next_cell).should be_false
      out.position.should eq 0
    end

    it "moves and wraps backwards, failing at the first cell" do
      doc, tbl = surrounded_table_doc
      c = doc.cursor(cell_start(tbl, 1, 0))
      c.move_position(:previous_cell).should be_true
      c.position.should eq cell_start(tbl, 0, 1)
      c.move_position(:previous_cell).should be_true
      c.position.should eq cell_start(tbl, 0, 0)
      c.move_position(:previous_cell).should be_false
    end

    it "repeats n times, stopping as far as it can" do
      doc, tbl = surrounded_table_doc
      c = doc.cursor(cell_start(tbl, 0, 0))
      c.move_position(:next_cell, n: 2).should be_true
      c.position.should eq cell_start(tbl, 1, 0)
      c.move_position(:next_cell, n: 10).should be_false
      c.position.should eq cell_start(tbl, 2, 1)
    end

    it "keeps the anchor in KeepAnchor mode" do
      doc, tbl = surrounded_table_doc
      c = doc.cursor(cell_start(tbl, 0, 0))
      c.move_position(:next_cell, :keep_anchor).should be_true
      c.anchor.should eq cell_start(tbl, 0, 0)
      c.position.should eq cell_start(tbl, 0, 1)
      c.selection?.should be_true
    end
  end

  describe "NextRow / PreviousRow" do
    it "moves to the same column of the adjacent row" do
      doc, tbl = surrounded_table_doc
      c = doc.cursor(cell_start(tbl, 0, 1))
      c.move_position(:next_row).should be_true
      c.position.should eq cell_start(tbl, 1, 1)
      c.move_position(:previous_row).should be_true
      c.position.should eq cell_start(tbl, 0, 1)
    end

    it "fails at the first and last rows" do
      doc, tbl = surrounded_table_doc
      doc.cursor(cell_start(tbl, 0, 0)).move_position(:previous_row).should be_false
      doc.cursor(cell_start(tbl, 2, 0)).move_position(:next_row).should be_false
    end
  end

  describe "Up / Down across table structure" do
    it "moves down into the table's first data row, snapped into a cell" do
      doc, tbl = surrounded_table_doc
      c = doc.cursor(0) # "above", column 0 — would land on the border glyph
      c.move_position(:down).should be_true
      c.position.should eq cell_start(tbl, 0, 0)
      tbl.cell_at(c.position).should eq({0, 0})
    end

    it "crosses the header/body separator row in both directions" do
      doc, tbl = surrounded_table_doc
      c = doc.cursor(cell_start(tbl, 0, 0))
      c.move_position(:down).should be_true
      tbl.cell_at(c.position).should eq({1, 0})
      c.move_position(:up).should be_true
      tbl.cell_at(c.position).should eq({0, 0})
    end

    it "leaves the table into the adjacent blocks, skipping borders" do
      doc, tbl = surrounded_table_doc
      c = doc.cursor(cell_start(tbl, 2, 0))
      c.move_position(:down).should be_true
      below = doc.block_at(c.position)
      doc.blocks[below.index].text.should eq "below"
      c2 = doc.cursor(cell_start(tbl, 0, 0))
      c2.move_position(:up).should be_true
      doc.blocks[doc.block_at(c2.position).index].text.should eq "above"
    end

    it "fails when only table structure remains in the direction" do
      doc = TextDocument.new("above")
      c = doc.cursor(doc.size)
      tbl = c.insert_table(["H1", "H2"], [["a", "b"]])
      last = doc.cursor(tbl.cell_text_range(1, 0).not_nil!.begin)
      last.move_position(:down).should be_false
    end
  end
end
