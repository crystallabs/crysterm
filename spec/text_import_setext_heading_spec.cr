require "./spec_helper"

include Crysterm

# A hard line break inside a setext heading splits it into two blocks, and the
# second is still the heading: it keeps the level, as the HTML importer keeps
# it on both sides of `<h2>a<br>b</h2>`. A soft break keeps one block.
describe "Markdown import of a setext heading with a line break" do
  it "keeps the level on the line after a two-space hard break" do
    doc = TextDocument.from_markdown("Line one  \nLine two\n===\n")
    doc.blocks.map { |b| {b.text, b.block_format.heading_level, b.source_line} }
      .should eq [{"Line one", 1, 1}, {"Line two", 1, 2}]
  end

  it "keeps the level on the line after a backslash hard break" do
    doc = TextDocument.from_markdown("Line one\\\nLine two\n---\n")
    doc.blocks.map { |b| {b.text, b.block_format.heading_level, b.source_line} }
      .should eq [{"Line one", 2, 1}, {"Line two", 2, 2}]
  end

  it "keeps a soft break inside one block with one outline entry" do
    doc = TextDocument.from_markdown("Line one\nLine two\n===\n")
    doc.blocks.map { |b| {b.text, b.block_format.heading_level} }.should eq [{"Line one Line two", 1}]
    doc.outline.size.should eq 1
  end

  it "matches the HTML importer, which keeps the level across a <br>" do
    doc = TextDocument.from_html("<h2>a<br>b</h2>")
    doc.blocks.map { |b| {b.text, b.block_format.heading_level} }.should eq [{"a", 2}, {"b", 2}]
  end

  it "leaves a hard break in a paragraph a plain continuation" do
    doc = TextDocument.from_markdown("# Title\n\none  \ntwo\n")
    doc.blocks.map { |b| {b.text, b.block_format.heading_level} }
      .should eq [{"Title", 1}, {"one", 0}, {"two", 0}]
  end
end
