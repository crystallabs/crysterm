require "./spec_helper"

include Crysterm

# Regression spec for BUGS17 B17-44 — the HTML importer's <br> branch derived
# the continuation block via a full copy_with that carried the paragraph's
# top_margin AND bottom_margin onto every continuation, fabricating phantom
# blank rows inside the paragraph and turning the hard break into a paragraph
# break on round-trip. The fix clears top_margin on the continuation and MOVES
# (not duplicates) bottom_margin to the paragraph's last line.
describe "BUGS17 HTML <br> margin duplication" do
  it "does not duplicate both margins onto the continuation" do
    doc = TextDocument.from_html(%(<p style="margin-top:2em;margin-bottom:1em">a<br>b</p>))
    doc.blocks[0].block_format.top_margin.should eq 2
    doc.blocks[0].block_format.bottom_margin.should eq 0
    doc.blocks[1].block_format.top_margin.should eq 0
    doc.blocks[1].block_format.bottom_margin.should eq 1
  end

  it "keeps an empty continuation equal to the default block format" do
    doc = TextDocument.from_html("<p>a<br>b</p>")
    doc.blocks[1].block_format.should eq TextBlockFormat.default
  end

  it "preserves the hard break as a markdown hard break, not a paragraph break" do
    doc = TextDocument.from_html("<p>x</p><p></p><p>a<br>b</p>")
    doc.to_markdown.should eq "x\n\na\\\nb"
  end
end
