require "./spec_helper"

include Crysterm

private def readings_table_of(doc : TextDocument) : TextTable
  TextTable.new(doc, doc.blocks.find!(&.block_format.table_format).block_format.table_format.not_nil!)
end

describe TextTable do
  it "keeps a run of spaces in a cell that fits its narrowed column only with the run closed up" do
    doc = TextDocument.new
    doc.set_markdown "| Key | What |\n| --- | --- |\n| abcd | aa bb cc dd ee ff gg hh |"
    tbl = readings_table_of(doc)
    tbl.set_cell_text(0, 0, "K  ey").should be_true
    doc.text_width = 16
    # The column is 4 wide: the cell shows as `K ey` on one line.
    tbl.row_block(0).not_nil!.text.should contain "│ K ey │"
    tbl.cell_text(0, 0).should eq "K  ey"
    doc.to_markdown.should contain "| K  ey |"
    doc.text_width = nil
    tbl.cell_text(0, 0).should eq "K  ey"
  end

  it "reads a row as its cells were after an undo across a width at which other cells render the same" do
    doc = TextDocument.new
    doc.text_width = 12
    doc.set_markdown "| A | B |\n| --- | --- |\n| abcdefghijkl | x |\n\npara"
    tbl = readings_table_of(doc)
    spaced = TextTable.split_data_row(tbl.row_block(1).not_nil!.text)[0]
    spaced.should_not eq "abcdefghijkl"
    doc.cursor(doc.size).insert_text("!")
    doc.text_width = 40
    tbl.set_cell_text(1, 0, spaced).should be_true
    # Back at 12 the spaced cell renders as the broken word did.
    doc.text_width = 12
    tbl.cell_text(1, 0).should eq spaced
    doc.undo.should be_true
    tbl.cell_text(1, 0).should eq "abcdefghijkl"
    doc.redo.should be_true
    tbl.cell_text(1, 0).should eq spaced
    doc.undo.should be_true
    doc.undo.should be_true
    tbl.cell_text(1, 0).should eq "abcdefghijkl"
    doc.to_plain_text.should_not contain "!"
  end

  it "reads a row as its cells were after undoing an edit whose rendering another edit later reused" do
    doc = TextDocument.new
    doc.text_width = 12
    doc.set_markdown "| A | B |\n| --- | --- |\n| abcdefghijkl | x |"
    tbl = readings_table_of(doc)
    spaced = TextTable.split_data_row(tbl.row_block(1).not_nil!.text)[0]
    tbl.set_cell_text(1, 0, "abcdefghijklm").should be_true
    tbl.set_cell_text(1, 0, spaced).should be_true
    doc.undo.should be_true
    tbl.cell_text(1, 0).should eq "abcdefghijklm"
    doc.undo.should be_true
    tbl.cell_text(1, 0).should eq "abcdefghijkl"
    doc.redo.should be_true
    doc.redo.should be_true
    tbl.cell_text(1, 0).should eq spaced
  end
end
