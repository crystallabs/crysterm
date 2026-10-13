require "./spec_helper"

# A `<pre>`'s margins are the code block's: the importer gives its top margin
# to the block's first line and its bottom margin to its last, not to every
# line, so the one `<pre>` the exporter writes a fenced block as reads back
# as the same lines, with no blank rows between them.
describe "TextHtml pre margins" do
  it "puts a pre's margins on its first and last lines only" do
    doc = Crysterm::TextDocument.from_html(%(<pre style="margin-top:1em;margin-bottom:2em">a\nb\nc</pre>))
    doc.blocks.map(&.block_format.top_margin).should eq [1, 0, 0]
    doc.blocks.map(&.block_format.bottom_margin).should eq [0, 0, 2]
  end

  it "round-trips a fenced block after a paragraph" do
    doc = Crysterm::TextDocument.from_markdown("p\n\n```\nx\ny\n```\n")
    back = Crysterm::TextDocument.from_html(doc.to_html)
    back.blocks.map(&.block_format.top_margin).should eq doc.blocks.map(&.block_format.top_margin)
    back.blocks.map(&.text).should eq ["p", "x", "y"]
  end
end
