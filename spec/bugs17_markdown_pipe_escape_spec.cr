require "./spec_helper"

include Crysterm

# BUGS17 B17-47 — Markdown export must escape a block-leading '|' so that a
# plain paragraph pair whose lines have the GFM table shape does not turn into
# a real table on re-import. B17-48 — a backtick-free code span with an edge
# space must be padded (so markd's edge-space strip restores it), while an
# all-space code span must stay unpadded (markd does not strip all-space).

describe "BUGS17 B17-47 block-leading pipe escaped on export" do
  it "keeps a pipe-shaped plain paragraph pair literal across a round-trip" do
    d = TextDocument.from_markdown(TextDocument.new("| a |\n| --- |").to_markdown)
    d.to_plain_text.should eq "| a |\n| --- |"
    d.blocks.size.should eq 2
    d.blocks.none?(&.block_format.table_format).should be_true
  end

  it "does not escape a mid-line pipe (stays a plain paragraph)" do
    d = TextDocument.from_markdown(TextDocument.new("a | b").to_markdown)
    d.to_plain_text.should eq "a | b"
    d.blocks.none?(&.block_format.table_format).should be_true
  end
end

describe "BUGS17 B17-48 code-span edge spaces survive round-trip" do
  it "preserves leading+trailing spaces of a backtick-free code fragment" do
    doc = TextDocument.from_markdown("`  x  `")
    doc.blocks[0].fragments[0].text.should eq " x "
    doc.blocks[0].fragments[0].format.code?.should be_true

    round = TextDocument.from_markdown(doc.to_markdown)
    round.blocks[0].fragments[0].text.should eq " x "
    round.blocks[0].fragments[0].format.code?.should be_true
  end

  it "does not pad an all-space code fragment" do
    doc = TextDocument.from_markdown("`   `")
    round = TextDocument.from_markdown(doc.to_markdown)
    round.blocks[0].fragments[0].text.should eq "   "
  end
end
