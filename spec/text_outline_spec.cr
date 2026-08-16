require "./spec_helper"

include Crysterm

# Document outline + github.com-shaped anchor slugs. Pure
# model: no widget is mounted anywhere in this file.

describe Crysterm::TextOutline do
  describe ".slug" do
    it "lowercases and hyphenates whitespace" do
      TextOutline.slug("Getting Started").should eq "getting-started"
    end

    it "drops punctuation but keeps dashes and underscores" do
      TextOutline.slug("What's new? (v2.0)").should eq "whats-new-v20"
      TextOutline.slug("snake_case and kebab-case").should eq "snake_case-and-kebab-case"
    end

    it "drops emoji and other non-lingual characters" do
      TextOutline.slug("Release 🎉 notes").should eq "release--notes"
    end

    it "keeps non-ASCII letters and digits" do
      TextOutline.slug("Über Café 42").should eq "über-café-42"
    end

    it "maps whitespace one-for-one, as github.com does" do
      TextOutline.slug("a  b").should eq "a--b"
    end

    it "strips leading and trailing whitespace before slugging" do
      TextOutline.slug("  Padded  ").should eq "padded"
    end

    it "yields an empty slug for a heading of pure punctuation" do
      TextOutline.slug("!!!").should eq ""
    end
  end

  describe Crysterm::TextOutline::Slugger do
    it "disambiguates repeats with a numeric suffix" do
      s = TextOutline::Slugger.new
      s.slug("Usage").should eq "usage"
      s.slug("Usage").should eq "usage-1"
      s.slug("Usage").should eq "usage-2"
      s.slug("Other").should eq "other"
    end

    it "disambiguates headings that differ only in dropped characters" do
      s = TextOutline::Slugger.new
      s.slug("API").should eq "api"
      s.slug("A.P.I.").should eq "api-1"
    end
  end
end

describe "TextDocument#outline" do
  it "lists headings in document order with level, text and anchor" do
    doc = TextDocument.from_markdown "# One\n\ntext\n\n## Two\n\n### Three"
    o = doc.outline
    o.map(&.level).should eq [1, 2, 3]
    o.map(&.text).should eq ["One", "Two", "Three"]
    o.map(&.anchor).should eq ["one", "two", "three"]
  end

  it "reports the block index each heading lives at" do
    doc = TextDocument.from_markdown "# One\n\nbody\n\n## Two"
    o = doc.outline
    doc.blocks[o[0].block].text.should eq "One"
    doc.blocks[o[1].block].text.should eq "Two"
  end

  it "is empty for a document with no headings" do
    TextDocument.from_markdown("just a paragraph").outline.should be_empty
  end

  it "disambiguates repeated headings across the document" do
    doc = TextDocument.from_markdown "## Options\n\na\n\n## Options"
    doc.outline.map(&.anchor).should eq ["options", "options-1"]
  end

  it "memoizes against the revision and recomputes after an edit" do
    doc = TextDocument.from_markdown "# One"
    first = doc.outline
    doc.outline.should be first
    doc.cursor(doc.size).insert_text(" and a half")
    doc.outline.should_not be first
    doc.outline.map(&.text).should eq ["One and a half"]
    doc.outline.map(&.anchor).should eq ["one-and-a-half"]
  end

  it "keeps the memoized outline across edits that touch no heading" do
    doc = TextDocument.from_markdown "# One\n\nbody"
    first = doc.outline
    doc.cursor(doc.size).insert_text(" grows")
    doc.outline.should be first
    doc.cursor(doc.size - 1, doc.size).remove_selected_text
    doc.outline.should be first
  end

  it "recomputes when a heading's level changes" do
    doc = TextDocument.from_markdown "# One\n\nbody"
    first = doc.outline
    doc.cursor(0, 0).merge_block_format(TextBlockFormat.new(heading_level: 2))
    doc.outline.should_not be first
    doc.outline.map(&.level).should eq [2]
  end

  it "recomputes when an edit shifts a heading to another block index" do
    doc = TextDocument.from_markdown "para\n\n# One"
    first = doc.outline
    first[0].block.should eq 1
    doc.cursor(0).insert_text("zero\n")
    doc.outline.should_not be first
    doc.outline[0].block.should eq 2
  end

  it "excludes headings that live inside a TOC frame" do
    doc = TextDocument.from_markdown "# Real"
    c = TextCursor.new doc
    c.set_position doc.size
    c.insert_toc TocOptions.new(title: "Contents")
    # The generated title is a heading block, but it sits in the frame.
    doc.blocks.any? { |b| b.text == "Contents" && b.block_format.heading? }.should be_true
    doc.outline.map(&.text).should eq ["Real"]
  end
end
