require "./spec_helper"

include Crysterm

# Regression spec for BUGS16 B16-50 — a heading inside a list item
# ("- # Title", which the importer stores as one block with BOTH list_format
# and heading_level) was silently exported as a plain list item by both the
# markdown and HTML exporters, downgrading the construct on every roundtrip.
describe "BUGS16 B16-50: heading-in-list-item export" do
  it "round-trips through markdown" do
    doc = TextDocument.from_markdown("- # Title\n- b")
    bf = doc.blocks[0].block_format
    bf.list_format.should_not be_nil
    bf.heading_level.should eq 1

    md = doc.to_markdown
    md.should eq "- # Title\n- b"

    round = TextDocument.from_markdown(md)
    round.blocks[0].block_format.heading_level.should eq 1
    round.blocks[0].block_format.list_format.should_not be_nil
  end

  it "round-trips through HTML" do
    doc = TextDocument.from_markdown("- # Title\n- b")
    html = doc.to_html
    html.should contain "<h1"

    round = TextDocument.from_html(html)
    rbf = round.blocks[0].block_format
    rbf.heading_level.should eq 1
    rbf.list_format.should_not be_nil
    round.blocks[0].text.should eq "Title"
  end

  it "leaves plain list items and standalone headings untouched" do
    TextDocument.from_markdown("- a\n- b").to_markdown.should eq "- a\n- b"
    TextDocument.from_markdown("# T").to_markdown.should eq "# T"
  end
end
