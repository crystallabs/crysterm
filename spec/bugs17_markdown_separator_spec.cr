require "./spec_helper"

include Crysterm

# Regression spec for BUGS17 B17-26 / B17-27 — the markdown Exporter emitted a
# bare newline (no blank line) at boundaries where CommonMark's lazy-
# continuation and GFM-table rules would merge the two blocks back into one on
# re-import. The blocks come from tags/HTML importers, which add no margins, so
# nothing else forces the separator. Each case must round-trip with its block
# structure preserved.
describe "BUGS17 markdown block separators" do
  # B17-26 case 1: a plain paragraph directly after a list item lazily
  # continues the item ("- a\nb" re-imports as one item "a b").
  it "keeps a paragraph after a list item from merging into it" do
    doc = TextDocument.from_tags("{!block;list-disc}a\nb")
    doc.block_count.should eq 2

    md = doc.to_markdown
    round = TextDocument.from_markdown(md)
    round.block_count.should eq 2
    round.blocks[0].block_format.list_format.should_not be_nil
    round.blocks[0].text.should eq "a"
    round.blocks[1].block_format.list_format.should be_nil
    round.blocks[1].text.should eq "b"
  end

  # B17-26 case 2: an ordered item whose rendered number is not 1 cannot
  # interrupt the preceding paragraph, so "a\n5. b" merges into one paragraph.
  it "keeps an <ol start> item from merging into a preceding paragraph" do
    doc = TextDocument.from_html(%(<p>a</p><ol start="5"><li>b</li></ol>))
    md = doc.to_markdown
    round = TextDocument.from_markdown(md)
    round.block_count.should eq 2
    round.blocks[0].block_format.list_format.should be_nil
    round.blocks[0].text.should eq "a"
    lf = round.blocks[1].block_format.list_format
    lf.should_not be_nil
    round.blocks[1].text.should eq "b"
  end

  # B17-27: a plain paragraph directly after a table run is swallowed as a
  # data row by the GFM table detector on re-import.
  it "keeps a paragraph after a table from becoming a table row" do
    doc = TextDocument.from_html("<table><tr><th>h</th></tr></table><p>b</p>")
    md = doc.to_markdown
    round = TextDocument.from_markdown(md)
    # The paragraph survives as a standalone, non-table block.
    para = round.blocks.find { |b| b.block_format.table_format.nil? && b.text == "b" }
    para.should_not be_nil
    # The table did not absorb "b" as a row: only the header data row remains
    # (#rows counts header + body, so header-only == 1; absorbing "b" would
    # make it 2).
    tf = round.blocks.compact_map(&.block_format.table_format).first
    table = TextTable.new(round, tf)
    table.rows.should eq 1
    table.cell_text(0, 0).should eq "h"
  end

  # B17-27 gap: two adjacent tables with distinct formats merge into one table
  # unless the exporter separates distinct table instances.
  it "keeps two adjacent distinct tables from merging into one" do
    doc = TextDocument.from_html(
      "<table><tr><th>a</th></tr></table><table><tr><th>b</th></tr></table>")
    md = doc.to_markdown
    round = TextDocument.from_markdown(md)
    tables = round.blocks.compact_map(&.block_format.table_format).map(&.object_id).uniq!
    tables.size.should eq 2
  end

  # Pinned behavior: two items of one list still export without a blank line.
  it "leaves two items of one list unchanged" do
    TextDocument.from_markdown("- a\n- b").to_markdown.should eq "- a\n- b"
  end
end
