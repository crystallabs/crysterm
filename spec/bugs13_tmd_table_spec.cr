require "./spec_helper"

include Crysterm

# BUGS13 T12 — GFM pipe escaping in table cells, both directions.

describe "BUGS13 GFM table pipe escaping (T12)" do
  it "imports \\| as a literal pipe inside a cell" do
    md = "| a \\| b | c |\n| --- | --- |\n| d | e \\| f |"
    doc = TextDocument.from_markdown(md)
    tf = doc.blocks.compact_map(&.block_format.table_format).first
    table = TextTable.new(doc, tf)
    table.columns.should eq 2
    table.rows.should eq 2
    table.cell_text(0, 0).should eq "a | b"
    table.cell_text(0, 1).should eq "c"
    table.cell_text(1, 1).should eq "e | f"
  end

  it "escapes literal pipes on export and round-trips them" do
    md = "| a \\| b | c |\n| --- | --- |\n| d | e \\| f |"
    doc = TextDocument.from_markdown(md)
    regen = doc.to_markdown
    regen.should contain "a \\| b"
    regen.should contain "e \\| f"
    back = TextDocument.from_markdown(regen)
    tf = back.blocks.compact_map(&.block_format.table_format).first
    table = TextTable.new(back, tf)
    table.columns.should eq 2
    table.cell_text(0, 0).should eq "a | b"
    table.cell_text(1, 1).should eq "e | f"
  end

  it "keeps unescaped-pipe splitting and outer-pipe stripping intact" do
    md = "a | b\n:--- | ---:\nc | d"
    doc = TextDocument.from_markdown(md)
    tf = doc.blocks.compact_map(&.block_format.table_format).first
    table = TextTable.new(doc, tf)
    table.columns.should eq 2
    table.cell_text(0, 0).should eq "a"
    table.cell_text(1, 1).should eq "d"
  end
end
