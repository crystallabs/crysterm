require "./spec_helper"

include Crysterm

# BUGS17 B17-46 — A table cell containing the box-drawing bar U+2502 must not be
# read as a column boundary. The build path now maps v_char inside a cell to an
# ASCII '|', so grid recovery, cell text, and the markdown round-trip agree with
# the declared column count (was: an extra recovered cell on every round-trip).

private def table_view(doc)
  tf = doc.blocks.find!(&.block_format.table_format).block_format.table_format.not_nil!
  TextTable.new(doc, tf)
end

describe "BUGS17 B17-46 bar glyph inside a table cell" do
  it "recovers 2 cells (not 3) from a markdown-imported bar cell" do
    d = TextDocument.from_markdown("| a│b | c |\n| --- | --- |")
    header = d.blocks.find! { |b| TextTable.data_row?(b.text) }
    TextTable.split_data_row(header.text).size.should eq 2

    t = table_view(d)
    t.cell_text(0, 0).should eq "a|b"
    t.cell_text(0, 1).should eq "c"
    t.cell_text(0, 2).should be_nil
  end

  it "round-trips markdown without emitting an extra cell" do
    d = TextDocument.from_markdown("| a│b | c |\n| --- | --- |")
    round = TextDocument.from_markdown(d.to_markdown)
    header = round.blocks.find! { |b| TextTable.data_row?(b.text) }
    TextTable.split_data_row(header.text).size.should eq 2
    table_view(round).cell_text(0, 0).should eq "a|b"
  end

  it "reproduces identically from the HTML entry point" do
    d = TextDocument.from_html("<table><tr><th>a│b</th><th>c</th></tr></table>")
    header = d.blocks.find! { |b| TextTable.data_row?(b.text) }
    TextTable.split_data_row(header.text).size.should eq 2
    t = table_view(d)
    t.cell_text(0, 0).should eq "a|b"
    t.cell_text(0, 1).should eq "c"
  end

  it "handles multiple bars in one cell" do
    d = TextDocument.from_markdown("| a│b│c | d |\n| --- | --- |")
    header = d.blocks.find! { |b| TextTable.data_row?(b.text) }
    TextTable.split_data_row(header.text).size.should eq 2
    t = table_view(d)
    t.cell_text(0, 0).should eq "a|b|c"
    t.cell_text(0, 1).should eq "d"
  end

  it "handles a cell that is only a bar" do
    d = TextDocument.from_markdown("| │ | c |\n| --- | --- |")
    header = d.blocks.find! { |b| TextTable.data_row?(b.text) }
    TextTable.split_data_row(header.text).size.should eq 2
    t = table_view(d)
    t.cell_text(0, 0).should eq "|"
    t.cell_text(0, 1).should eq "c"
  end
end
