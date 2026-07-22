require "./spec_helper"

include Crysterm

# BUGS17 B17-28 — Markdown export must keep a fenced code block inside its list
# item. The importer stamps a code block that lives in a list item with the
# item's `indent` (continuation) or `list_format` (the item's first content),
# but Exporter#export's fence branch used to write the fence and every code
# line at column 0 with no indent and no item marker, detaching the code block
# from the list on re-import (and, when the fence was the item's first content,
# dropping the bullet and shifting ordered numbering). Pure model (TextMarkdown).

private def code_block?(b)
  !b.block_format.bg.nil?
end

describe "BUGS17 B17-28 fenced code block inside a list item round-trips" do
  it "keeps a code block as continuation content inside its item" do
    md = "- item\n\n  ```\n  code\n  ```"
    doc = Crysterm::TextDocument.from_markdown(md)

    # Sanity: import produced [item(list), code(bg, indent 2)].
    doc.blocks[0].block_format.list_format.should_not be_nil
    doc.blocks[1].block_format.bg.should_not be_nil
    doc.blocks[1].block_format.indent.should eq 2

    round = Crysterm::TextDocument.from_markdown(doc.to_markdown)
    round.blocks.size.should eq 2
    # The list item survives...
    round.blocks[0].block_format.list_format.should_not be_nil
    round.blocks[0].text.should eq "item"
    # ...and the code block stays inside it (nonzero indent, still code-bg).
    code = round.blocks[1]
    code_block?(code).should be_true
    code.block_format.indent.should be > 0
    code.text.should eq "code"
    # Stable across a second cycle.
    doc.to_markdown.should eq round.to_markdown
  end

  it "keeps the bullet when the code block is the item's only content" do
    md = "- ```\n  code\n  ```"
    doc = Crysterm::TextDocument.from_markdown(md)

    # Import: the single code block carries the item's list_format.
    doc.blocks.size.should eq 1
    doc.blocks[0].block_format.list_format.should_not be_nil
    doc.blocks[0].block_format.bg.should_not be_nil

    round = Crysterm::TextDocument.from_markdown(doc.to_markdown)
    round.blocks.size.should eq 1
    first = round.blocks[0]
    # The bullet is preserved: list_format present AND still a code block.
    first.block_format.list_format.should_not be_nil
    code_block?(first).should be_true
    first.text.should eq "code"
    doc.to_markdown.should eq round.to_markdown
  end

  it "keeps ordered numbering intact after a fence-only item" do
    md = "1. ```\n   code\n   ```\n2. second"
    doc = Crysterm::TextDocument.from_markdown(md)

    doc.blocks.size.should eq 2
    doc.blocks[0].block_format.list_format.try(&.style.decimal?).should be_true
    doc.blocks[0].block_format.bg.should_not be_nil
    doc.blocks[1].block_format.list_format.try(&.style.decimal?).should be_true

    exported = doc.to_markdown
    # The second item must remain "2. ", not restart at 1.
    exported.should contain "2. second"

    round = Crysterm::TextDocument.from_markdown(exported)
    round.blocks.size.should eq 2
    # Fence-only item keeps its list membership...
    round.blocks[0].block_format.list_format.try(&.style.decimal?).should be_true
    code_block?(round.blocks[0]).should be_true
    # ...and the following item is still an ordered item with the right text.
    round.blocks[1].block_format.list_format.try(&.style.decimal?).should be_true
    round.blocks[1].text.should eq "second"
    exported.should eq round.to_markdown
  end
end
