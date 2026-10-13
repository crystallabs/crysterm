require "./spec_helper"

include Crysterm

# A table whose blocks raw `TextCursor` edits put other blocks between, or
# cut a row of short — states `Widget::TextEdit` never produces, the public
# cursor API can.

private def torn_table_of(doc : TextDocument) : TextTable
  TextTable.new(doc, doc.blocks.find!(&.block_format.table_format).block_format.table_format.not_nil!)
end

private TORN_MD = "| A | B |\n| --- | --- |\n| a1 | b1 |\n| a2 | b2 |\n| a3 | b3 |\n\ntail"

# The document of TORN_MD with a pasted "p1", "", "p2" splitting row a2's
# block at its start: "p1" and "" are blocks of their own between rows a1
# and a2.
private def torn_doc : TextDocument
  doc = TextDocument.new
  doc.set_markdown TORN_MD
  tbl = torn_table_of(doc)
  pos = tbl.row_block(2).not_nil!.position
  doc.cursor(pos).insert_fragment(TextDocumentFragment.from_markdown("p1\n\np2"))
  doc
end

describe TextTable do
  it "rewrites a cell of a table with other blocks between its rows, keeping those blocks" do
    doc = torn_doc
    before = doc.to_plain_text
    tbl = torn_table_of(doc)
    tbl.set_cell_text(0, 0, "Head").should be_true
    texts = doc.blocks.map(&.text)
    texts.should contain "p1"
    texts.any?(&.starts_with?("p2")).should be_true
    tbl.cell_text(0, 0).should eq "Head"
    tbl.cell_text(1, 0).should eq "a1"
    texts.last.should eq "tail"
    doc.undo.should be_true
    doc.to_plain_text.should eq before
  end

  it "adds and removes rows and columns of a table with other blocks between its rows" do
    doc = torn_doc
    before = doc.to_plain_text
    tbl = torn_table_of(doc)
    rows = tbl.rows
    tbl.insert_row(rows, ["n1", "n2"]).should be_true
    tbl.rows.should eq rows + 1
    tbl.cell_text(rows, 0).should eq "n1"
    tbl.remove_row(1).should be_true
    tbl.rows.should eq rows
    tbl.insert_column(2, "C").should be_true
    tbl.columns.should eq 3
    tbl.cell_text(0, 2).should eq "C"
    tbl.remove_column(0).should be_true
    tbl.columns.should eq 2
    doc.blocks.map(&.text).should contain "p1"
    4.times { doc.undo.should be_true }
    doc.to_plain_text.should eq before
  end

  it "takes a row cut short as having empty cells past its end" do
    doc = TextDocument.new
    doc.set_markdown TORN_MD
    tbl = torn_table_of(doc)
    b = tbl.row_block(1).not_nil!
    # Row a1 loses its last cell and closing bar: "│ a1 │".
    cut = b.text.index!("b1") - 1
    doc.cursor(b.position + cut, b.position + b.size).remove_selected_text
    tbl.cell_text(1, 0).should eq "a1"
    tbl.cell_text(1, 1).should eq ""
    tbl.cell_text(1, 2).should be_nil
    tbl.insert_column(2).should be_true
    tbl.cell_text(1, 0).should eq "a1"
    tbl.cell_text(1, 1).should eq ""
    tbl.cell_text(2, 1).should eq "b2"
  end

  it "leaves a table with other blocks between its rows as it is at a new width" do
    doc = TextDocument.new
    doc.set_markdown TORN_MD
    tbl = torn_table_of(doc)
    tbl.set_cell_text(1, 0, "a long cell that wraps").should be_true
    # A line typed after the header row, and the table torn after the
    # border below it: its first blocks alone have the shape of a table
    # of one row (border, row, line, border).
    hdr = tbl.row_block(0).not_nil!
    doc.cursor(hdr.position + hdr.size).insert_text("\nx")
    sep = doc.blocks[3]
    doc.cursor(sep.position + sep.size).insert_fragment(TextDocumentFragment.from_markdown("p1\n\np2"))
    before = doc.to_plain_text
    doc.text_width = 14
    doc.to_plain_text.should eq before
  end

  it "reads a row as its cells were after undoing a removal that joined it to the row above, past an edit of it" do
    doc = TextDocument.new
    doc.text_width = 12
    doc.set_markdown "| A | B |\n| --- | --- |\n| abcdefghijkl | x |\n| mnopqrstuvwx | y |"
    tbl = torn_table_of(doc)
    tbl.row_block(1).not_nil!.table_cells.should_not be_nil
    tbl.row_block(2).not_nil!.table_cells.should_not be_nil
    # A raw edit of row 2's text leaves its remembered cells behind it.
    b2 = tbl.row_block(2).not_nil!
    doc.cursor(b2.position + 2, b2.position + 3).remove_selected_text
    # Row 2 joined onto row 1's end, then put back by undo.
    b1 = tbl.row_block(1).not_nil!
    b2 = tbl.row_block(2).not_nil!
    doc.cursor(b1.position + b1.size, b2.position + b2.size).remove_selected_text
    doc.undo.should be_true
    doc.undo.should be_true
    tbl.cell_text(1, 0).should eq "abcdefghijkl"
    tbl.cell_text(2, 0).should eq "mnopqrstuvwx"
  end

  it "gives back a row that needs no remembered cells as itself on undoing a removal from a row that renders alike" do
    doc = TextDocument.new
    doc.text_width = 20
    # The rows render alike: the second's space is where the first's word
    # breaks, so only the first needs its cells remembered.
    doc.set_markdown "| A |\n| --- |\n| abcdefghijklmnopqrstuvwxyz |\n| abcdefghijklmnop qrstuvwxyz |"
    tbl = torn_table_of(doc)
    b1 = tbl.row_block(1).not_nil!
    b2 = tbl.row_block(2).not_nil!
    b1.text.should eq b2.text
    b1.table_cells.should_not be_nil
    b2.table_cells.should be_nil
    doc.cursor(b1.position + 3, b2.position + 3).remove_selected_text
    doc.undo.should be_true
    tbl.cell_text(1, 0).should eq "abcdefghijklmnopqrstuvwxyz"
    tbl.cell_text(2, 0).should eq "abcdefghijklmnop qrstuvwxyz"
  end
end
