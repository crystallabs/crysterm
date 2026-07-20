require "./spec_helper"

include Crysterm

# B16-47: markdown export at a quote-level decrease must not emit a bare
# newline between the deeper and shallower block. Under CommonMark's lazy
# continuation, the shallower plain-body line would continue the inner
# quote's paragraph, merging the two blocks' text into one on re-import.
# Export has to break the run (a ">"-only line at the lower level, or a
# blank line when decreasing to level 0) so the round-trip is idempotent.

private def block_shapes(doc : Crysterm::TextDocument) : Array({String, Int32})
  doc.blocks.map { |b| {b.text, b.block_format.quote_level} }
end

describe Crysterm::TextMarkdown do
  describe "quote-level decrease export (B16-47)" do
    it "does not merge a shallower plain body block into a deeper quote" do
      doc = TextDocument.from_markdown("> > deep\n>\n> shallow")
      orig = block_shapes(doc)
      # The blank line between "deep" and "shallow" is itself a quote-level
      # separator block at the shallower level (B16-49: import_paragraph
      # emits it whenever @quote_depth > 0, same as the heading/code paths —
      # "> > deep\n>\n> # heading" produces the identical {"", 1} shape).
      orig.should eq [{"deep", 2}, {"", 1}, {"shallow", 1}]

      md = doc.to_markdown
      round = block_shapes(TextDocument.from_markdown(md))
      # Re-import must preserve the three blocks — not collapse to one merged
      # {"deep shallow", 2} block (the pre-fix corruption).
      round.should eq orig
    end

    it "round-trips a quote-level decrease following a list item" do
      doc = TextDocument.from_markdown("> > - item\n>\n> shallow")
      md = doc.to_markdown
      round = TextDocument.from_markdown(md)
      # The list item and the shallower paragraph must survive as separate
      # blocks — no lazy merge of "shallow" into the list item's paragraph.
      round.blocks.last.text.should eq "shallow"
      round.blocks.last.block_format.quote_level.should eq 1
      round.blocks.any? { |b| b.block_format.list_format && b.text == "item" }.should be_true
      round.block_count.should eq doc.block_count
    end

    it "keeps text intact when decreasing all the way to level 0" do
      doc = TextDocument.from_markdown("> quoted\n\nplain")
      orig = block_shapes(doc)
      orig.should eq [{"quoted", 1}, {"plain", 0}]
      md = doc.to_markdown
      block_shapes(TextDocument.from_markdown(md)).should eq orig
    end
  end
end
