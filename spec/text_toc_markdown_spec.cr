require "./spec_helper"

include Crysterm

# Markdown interchange for the inline TOC (TOC.md Phase 6): the comment fence
# on export, fence *and* bare markers on import.

private def toc_of(doc : Crysterm::TextDocument) : Crysterm::TextToc
  doc.tocs.first
end

describe "TextMarkdown TOC interchange" do
  describe "import" do
    it "folds a comment fence into a TOC frame and regenerates it" do
      doc = TextDocument.from_markdown <<-MD
        <!-- toc -->

        - [Stale](#stale)

        <!-- tocstop -->

        # One

        ## Two
        MD
      doc.tocs.size.should eq 1
      toc_of(doc).blocks.map(&.text).should eq ["One", "Two"]
    end

    it "drops the fence blocks themselves" do
      doc = TextDocument.from_markdown "<!-- toc -->\n\n<!-- tocstop -->\n\n# One"
      doc.blocks.map(&.text).should_not contain "<!-- toc -->"
      doc.blocks.map(&.text).should_not contain "<!-- tocstop -->"
    end

    it "handles an empty fence" do
      doc = TextDocument.from_markdown "<!-- toc -->\n<!-- tocstop -->\n\n# One"
      toc_of(doc).blocks.map(&.text).should eq ["One"]
    end

    {"[TOC]", "[toc]", "[[TOC]]", "[[_TOC_]]"}.each do |marker|
      it "accepts the bare #{marker} marker" do
        doc = TextDocument.from_markdown "#{marker}\n\n# One\n\n## Two"
        doc.tocs.size.should eq 1
        toc_of(doc).blocks.map(&.text).should eq ["One", "Two"]
      end
    end

    it "leaves an unterminated fence as a literal HTML comment" do
      doc = TextDocument.from_markdown "<!-- toc -->\n\n# One"
      doc.tocs.should be_empty
      doc.blocks.map(&.text).should contain "<!-- toc -->"
    end

    it "does not treat a marker inside a code fence as a TOC" do
      doc = TextDocument.from_markdown "```\n[TOC]\n```"
      doc.tocs.should be_empty
    end
  end

  describe "export" do
    it "brackets the region with the fence and writes real links" do
      doc = TextDocument.from_markdown "[TOC]\n\n# One\n\n## Two"
      md = doc.to_markdown
      md.should contain "<!-- toc -->"
      md.should contain "<!-- tocstop -->"
      md.should contain "[One](#one)"
      md.should contain "[Two](#two)"
    end

    it "normalizes every accepted bare marker to the fence" do
      doc = TextDocument.from_markdown "[[_TOC_]]\n\n# One"
      md = doc.to_markdown
      md.should contain "<!-- toc -->"
      md.should_not contain "[[_TOC_]]"
    end

    it "writes plain text entries when links are off" do
      doc = TextDocument.from_markdown "# One"
      c = TextCursor.new doc
      c.set_position 0
      c.insert_toc TocOptions.new(links: false)
      md = doc.to_markdown
      md.should contain "<!-- toc -->"
      md.should_not contain "(#one)"
    end

    it "emits nothing TOC-shaped for a document without one" do
      md = TextDocument.from_markdown("# One").to_markdown
      md.should_not contain "<!-- toc -->"
    end
  end

  describe "round-trip" do
    it "is stable across import → export → import" do
      src = "[TOC]\n\n# One\n\n## Two\n\n# Three"
      once = TextDocument.from_markdown(src).to_markdown
      twice = TextDocument.from_markdown(once).to_markdown
      twice.should eq once
    end

    it "keeps the TOC a TOC, not a plain list" do
      doc = TextDocument.from_markdown "[TOC]\n\n# One"
      again = TextDocument.from_markdown doc.to_markdown
      again.tocs.size.should eq 1
      toc_of(again).blocks.map(&.text).should eq ["One"]
    end

    it "tracks headings added between round-trips" do
      doc = TextDocument.from_markdown "[TOC]\n\n# One"
      grown = TextDocument.from_markdown "#{doc.to_markdown}\n\n## Two"
      toc_of(grown).blocks.map(&.text).should eq ["One", "Two"]
    end

    it "survives a title" do
      doc = TextDocument.from_markdown "# One\n\n## Two"
      c = TextCursor.new doc
      c.set_position 0
      c.insert_toc TocOptions.new(title: "Contents", min_level: 1)
      again = TextDocument.from_markdown doc.to_markdown
      again.tocs.size.should eq 1
      again.to_markdown.should eq doc.to_markdown
    end
  end
end
