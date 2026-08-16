require "./spec_helper"

include Crysterm

# Inline table of contents: a `TextToc` frame whose
# entries are ordinary list blocks. Pure model.

private def toc_doc(md : String, opts = Crysterm::TocOptions.new) : Crysterm::TextDocument
  doc = Crysterm::TextDocument.from_markdown md
  c = Crysterm::TextCursor.new doc
  c.set_position 0
  c.insert_toc opts
  doc
end

# The text of the blocks belonging to the document's first TOC.
private def toc_lines(doc : Crysterm::TextDocument) : Array(String)
  doc.tocs.first.blocks.map(&.text)
end

describe Crysterm::TextToc do
  describe "TextCursor#insert_toc" do
    it "builds one entry per heading, in document order" do
      doc = toc_doc "# One\n\n## Two\n\n# Three"
      toc_lines(doc).should eq ["One", "Two", "Three"]
    end

    it "leaves the document's own content intact" do
      doc = toc_doc "# One\n\nbody"
      doc.blocks.map(&.text).should contain "body"
      doc.outline.map(&.text).should eq ["One"]
    end

    it "links entries to their heading anchors by default" do
      doc = toc_doc "# One\n\n## Two"
      hrefs = doc.tocs.first.blocks.map(&.fragments.first.format.anchor_href)
      hrefs.should eq ["#one", "#two"]
    end

    it "omits anchors when links are off" do
      doc = toc_doc "# One", TocOptions.new(links: false)
      doc.tocs.first.blocks.first.fragments.first.format.anchor_href.should be_nil
    end

    it "nests entries by heading level via the list format indent" do
      doc = toc_doc "# One\n\n## Two\n\n### Three\n\n# Four"
      indents = doc.tocs.first.blocks.map(&.block_format.list_format.not_nil!.indent)
      indents.should eq [1, 2, 3, 1]
    end

    it "restarts ordered numbering per sibling group" do
      doc = toc_doc "# A\n\n## A1\n\n## A2\n\n# B\n\n## B1",
        TocOptions.new(numbering: :ordered)
      lfs = doc.tocs.first.blocks.map(&.block_format.list_format.not_nil!)
      # A/B share the top-level list; A1/A2 share one nested list, and B1 gets a
      # fresh one so it is numbered 1 rather than 3.
      lfs[0].should be lfs[3]
      lfs[1].should be lfs[2]
      lfs[4].should_not be lfs[1]
      list = TextList.new doc, lfs[4]
      list.item_number(doc.tocs.first.blocks[4]).should eq 0
    end

    it "honors min_level and max_level" do
      doc = toc_doc "# Title\n\n## Two\n\n### Three\n\n#### Four",
        TocOptions.new(min_level: 2, max_level: 3)
      toc_lines(doc).should eq ["Two", "Three"]
      # The shallowest included level becomes the top nesting level.
      doc.tocs.first.blocks.map(&.block_format.list_format.not_nil!.indent).should eq [1, 2]
    end

    it "emits a title heading that does not index itself" do
      doc = toc_doc "# One", TocOptions.new(title: "Contents")
      toc_lines(doc).should eq ["Contents", "One"]
      doc.tocs.first.blocks.first.block_format.heading_level.should eq 1
      doc.outline.map(&.text).should eq ["One"]
    end

    it "occupies a single empty block when there are no headings" do
      doc = toc_doc "no headings here"
      toc_lines(doc).should eq [""]
    end

    it "is one undo step" do
      doc = TextDocument.from_markdown "# One\n\n## Two"
      before = doc.to_plain_text
      c = TextCursor.new doc
      c.set_position 0
      c.insert_toc
      doc.to_plain_text.should_not eq before
      doc.undo.should be_true
      doc.to_plain_text.should eq before
      doc.tocs.should be_empty
    end

    it "keeps the TOC inside the frame it was inserted into" do
      doc = TextDocument.from_markdown "> quoted\n\n# One"
      c = TextCursor.new doc
      c.set_position 0
      toc = c.insert_toc
      toc.blocks.first.block_format.quote_level.should eq 1
    end
  end

  describe "#refresh" do
    it "picks up a heading added after insertion" do
      doc = toc_doc "# One"
      toc_lines(doc).should eq ["One"]
      c = TextCursor.new doc
      c.set_position doc.size
      c.insert_block TextBlockFormat.new(heading_level: 2)
      c.insert_text "Two"
      doc.refresh_tocs.should be_true
      toc_lines(doc).should eq ["One", "Two"]
    end

    it "does not update until asked" do
      doc = toc_doc "# One"
      c = TextCursor.new doc
      c.set_position doc.size
      c.insert_block TextBlockFormat.new(heading_level: 2)
      c.insert_text "Two"
      toc_lines(doc).should eq ["One"]
    end

    it "mutates nothing when the outline is unchanged" do
      doc = toc_doc "# One\n\n## Two"
      rev = doc.revision
      doc.refresh_tocs.should be_false
      doc.revision.should eq rev
    end

    it "records no undo command" do
      doc = toc_doc "# One"
      c = TextCursor.new doc
      c.set_position doc.size
      c.insert_block TextBlockFormat.new(heading_level: 2)
      c.insert_text "Two"
      before = doc.to_plain_text
      doc.refresh_tocs.should be_true
      # Undo reverses the *user* edit that added the heading, never the
      # regeneration: the TOC region is derived data outside the stack.
      doc.undo
      doc.to_plain_text.should_not eq before
      doc.to_plain_text.lines.should contain "Two"
    end

    it "tracks a heading whose text changed" do
      doc = toc_doc "# One"
      hb = doc.outline.first.block
      doc.cursor(doc.block_position(hb) + 3).insert_text(" Point Five")
      doc.refresh_tocs.should be_true
      toc_lines(doc).should eq ["One Point Five"]
      doc.tocs.first.blocks.first.fragments.first.format.anchor_href.should eq "#one-point-five"
    end

    it "shrinks when headings are removed" do
      doc = toc_doc "# One\n\n## Two"
      toc_lines(doc).size.should eq 2
      hb = doc.outline.last.block
      from = doc.block_position(hb)
      doc.cursor(from - 1, from + doc.blocks[hb].size).remove_selected_text
      doc.refresh_tocs.should be_true
      toc_lines(doc).should eq ["One"]
    end
  end

  describe "#remove" do
    it "takes the region out of the document" do
      doc = toc_doc "# One\n\nbody"
      doc.tocs.size.should eq 1
      doc.tocs.first.remove.should be_true
      doc.tocs.should be_empty
      doc.to_plain_text.lines.should eq ["One", "body"]
    end
  end

  describe "TextDocument#tocs" do
    it "finds every TOC, in document order" do
      doc = TextDocument.from_markdown "# One\n\n## Two"
      c = TextCursor.new doc
      c.set_position 0
      c.insert_toc
      c.set_position doc.size
      c.insert_toc TocOptions.new(min_level: 2)
      doc.tocs.size.should eq 2
      doc.tocs[0].blocks.map(&.text).should eq ["One", "Two"]
      doc.tocs[1].blocks.map(&.text).should eq ["Two"]
    end
  end

  describe "frame membership" do
    it "survives a clipboard round-trip" do
      doc = toc_doc "# One\n\n## Two"
      toc = doc.tocs.first
      first, last = toc.block_range.not_nil!
      from = doc.block_position(first)
      to = doc.block_position(last) + doc.blocks[last].size
      frag = doc.copy_fragment(from, to)
      target = TextDocument.new
      target.cursor(0).insert_fragment(frag)
      target.tocs.size.should eq 1
    end
  end
end
