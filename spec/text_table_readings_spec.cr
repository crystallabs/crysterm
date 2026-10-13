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

  it "reads two rows that render alike each as its own cells" do
    doc = TextDocument.new
    doc.text_width = 12
    doc.set_markdown "| A | B |\n| --- | --- |\n| abcdefghijkl | x |\n| y | x |"
    tbl = readings_table_of(doc)
    spaced = TextTable.split_data_row(tbl.row_block(1).not_nil!.text)[0]
    tbl.set_cell_text(2, 0, spaced).should be_true
    tbl.row_block(2).not_nil!.text.should eq tbl.row_block(1).not_nil!.text
    tbl.cell_text(1, 0).should eq "abcdefghijkl"
    tbl.cell_text(2, 0).should eq spaced
    doc.text_width = nil
    tbl.cell_text(1, 0).should eq "abcdefghijkl"
    tbl.cell_text(2, 0).should eq spaced
    doc.text_width = 12
    doc.undo.should be_true
    tbl.cell_text(1, 0).should eq "abcdefghijkl"
    tbl.cell_text(2, 0).should eq "y"
    doc.redo.should be_true
    tbl.cell_text(2, 0).should eq spaced
  end

  it "gives back a cut wrapped row's cells on undo" do
    doc = TextDocument.new
    doc.text_width = 12
    doc.set_markdown "| A | B |\n| --- | --- |\n| abcdefghijkl | x |\n| y | x |"
    tbl = readings_table_of(doc)
    b = tbl.row_block(1).not_nil!
    doc.cursor(b.position - 1, b.position + b.size).remove_selected_text
    tbl.cell_text(1, 0).should eq "y"
    doc.undo.should be_true
    tbl.cell_text(1, 0).should eq "abcdefghijkl"
  end

  it "makes a pasted copy of a table a table of its own" do
    doc = TextDocument.new
    doc.text_width = 12
    doc.set_markdown "| A | B |\n| --- | --- |\n| abcdefghijkl | x |\n\npara"
    tbl = readings_table_of(doc)
    frag = doc.copy_fragment(0, tbl.row_block(1).not_nil!.position + 200)
    doc.cursor(doc.size).insert_fragment(frag)
    formats = doc.blocks.compact_map(&.block_format.table_format).uniq!(&.object_id)
    formats.size.should eq 2
    copy = TextTable.new(doc, formats[1])
    copy.cell_text(1, 0).should eq "abcdefghijkl"
    tbl.rows.should eq 2
    tbl.set_cell_text(1, 0, "z").should be_true
    copy.cell_text(1, 0).should eq "abcdefghijkl"
    doc.to_markdown.scan("| abcdefghijkl |").size.should eq 1
  end

  it "gives back a wrapped row's cells on undoing a removal that joined the row to the block above" do
    doc = TextDocument.new
    doc.text_width = 12
    doc.set_markdown "para\n\n| A | B |\n| --- | --- |\n| abcdefghijkl | x |"
    tbl = readings_table_of(doc)
    b = tbl.row_block(1).not_nil!
    # From inside the paragraph to the row's start: the row's text joins
    # the paragraph's block.
    doc.cursor(2, b.position).remove_selected_text
    doc.undo.should be_true
    readings_table_of(doc).cell_text(1, 0).should eq "abcdefghijkl"
  end

  it "gives back a wrapped row's cells on undoing blocks inserted at the row's start" do
    {TextDocumentFragment.from_markdown("p1\n\np2"), nil}.each do |frag|
      doc = TextDocument.new
      doc.text_width = 12
      doc.set_markdown "| A | B |\n| --- | --- |\n| abcdefghijkl | x |\n\npara"
      pos = readings_table_of(doc).row_block(1).not_nil!.position
      frag ? doc.cursor(pos).insert_fragment(frag) : doc.cursor(pos).insert_text("\n")
      doc.undo.should be_true
      readings_table_of(doc).cell_text(1, 0).should eq "abcdefghijkl"
    end
  end
end
