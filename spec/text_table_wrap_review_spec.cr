require "./spec_helper"

include Crysterm

private def table_of(doc : TextDocument) : TextTable
  TextTable.new(doc, doc.blocks.find!(&.block_format.table_format).block_format.table_format.not_nil!)
end

describe TextTable do
  it "keeps a space typed at a word's mid-way break, though the rendering is the same" do
    doc = TextDocument.new
    doc.text_width = 12
    doc.set_markdown "| A | B |\n| --- | --- |\n| abcdefghijkl | x |"
    tbl = table_of(doc)
    tbl.cell_text(1, 0).should eq "abcdefghijkl"
    # The row as it looks: a space at each break of the word.
    spaced = TextTable.split_data_row(tbl.row_block(1).not_nil!.text)[0]
    spaced.should_not eq "abcdefghijkl"
    tbl.set_cell_text(1, 0, spaced).should be_true
    tbl.cell_text(1, 0).should eq spaced
    doc.to_markdown.should contain spaced
  end
end
