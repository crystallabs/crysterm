require "./spec_helper"

include Crysterm

# `TextTable` (TEXTEDIT.md Phase 4, read-only cut): GFM/HTML tables import
# as pre-rendered box-drawing blocks sharing one `TextTableFormat` instance;
# the view class recovers the grid and the exporters round-trip it.

private GFM = "| Name | N |\n| --- | ---: |\n| ab | 1 |\n| c | 22 |"

describe Crysterm::TextTable do
  it "imports a GFM table as bordered, column-padded blocks" do
    doc = TextDocument.from_markdown(GFM)
    tf = doc.blocks[0].block_format.table_format.not_nil!
    tf.columns.should eq 2
    # Header + 2 data rows + 3 border rows = 6 blocks.
    doc.block_count.should eq 6
    doc.blocks[0].text.should eq "┌──────┬────┐"
    doc.blocks[1].text.should eq "│ Name │  N │" # N right-aligned
    doc.blocks[2].text.should eq "├──────┼────┤"
    doc.blocks[3].text.should eq "│ ab   │  1 │"
    doc.blocks[5].text.should eq "└──────┴────┘"
    # All blocks share the one instance; the header renders bold.
    doc.blocks.all?(&.block_format.table_format.same?(tf)).should be_true
    doc.blocks[1].fragments[1].format.bold?.should be_true
    doc.blocks[3].fragments[1].format.bold?.should be_false
  end

  it "recovers the grid through the view class" do
    doc = TextDocument.from_markdown(GFM)
    table = TextTable.new(doc, doc.blocks[0].block_format.table_format.not_nil!)
    table.rows.should eq 3
    table.columns.should eq 2
    table.cell_text(0, 0).should eq "Name"
    table.cell_text(1, 1).should eq "1"
    table.cell_text(2, 0).should eq "c"
    table.cell_text(3, 0).should be_nil
  end

  it "round-trips GFM including column alignment" do
    TextDocument.from_markdown(GFM).to_markdown.should eq GFM
  end

  it "keeps a table inside a blockquote" do
    md = "> | a | b |\n> | --- | --- |\n> | 1 | 2 |"
    doc = TextDocument.from_markdown(md)
    doc.blocks[0].block_format.quote_level.should eq 1
    doc.blocks[0].block_format.table_format.should_not be_nil
    doc.to_markdown.should eq md
  end

  it "imports an HTML table and cross-converts" do
    doc = TextDocument.from_html("<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table>")
    tf = doc.blocks[0].block_format.table_format.not_nil!
    table = TextTable.new(doc, tf)
    table.rows.should eq 2
    table.cell_text(0, 1).should eq "b"
    table.cell_text(1, 0).should eq "1"

    html = doc.to_html
    html.should contain "<table><tr><th>a</th><th>b</th></tr>"
    html.should contain "<td>1</td>"
    doc.to_markdown.should eq "| a | b |\n| --- | --- |\n| 1 | 2 |"
  end

  it "renders through Widget::TextEdit as plain geometry" do
    s = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 30, height: 8)
    te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 30, height: 8
    te.set_markdown "| a | b |\n| --- | --- |\n| 1 | 2 |"
    s.repaint
    String.build { |io| 9.times { |x| io << s.lines[0][x].char } }.should eq "┌───┬───┐"
    String.build { |io| 9.times { |x| io << s.lines[1][x].char } }.should eq "│ a │ b │"
  end
end
