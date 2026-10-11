require "./spec_helper"

include Crysterm

# Whitespace inside Markdown text. CommonMark keeps a paragraph line's runs
# of spaces and tabs in the text and leaves the collapsing to the renderer —
# the HTML renderers pass them through and the browser collapses them. A
# terminal has no browser in front of it, so the importer collapses on the
# way in: runs to one space, a soft break to a space, nothing at a block's
# start or doubled across inline nodes. Code spans, code blocks and raw HTML
# blocks keep their spacing, as they would in a browser.
describe "Markdown whitespace" do
  describe "import" do
    it "collapses a run of spaces in a paragraph to one" do
      TextDocument.from_markdown("a    b").blocks[0].text.should eq "a b"
    end

    it "collapses tabs and mixed runs to one space" do
      TextDocument.from_markdown("a\t\tb").blocks[0].text.should eq "a b"
      TextDocument.from_markdown("a \t  b").blocks[0].text.should eq "a b"
    end

    it "renders a soft line break as one space" do
      doc = TextDocument.from_markdown("one\ntwo")
      doc.blocks.size.should eq 1
      doc.blocks[0].text.should eq "one two"
    end

    it "keeps a hard break as a line break, with nothing left over at either edge" do
      doc = TextDocument.from_markdown("one  \n   two")
      doc.blocks.map(&.text).should eq ["one", "two"]
      doc = TextDocument.from_markdown("one\\\ntwo")
      doc.blocks.map(&.text).should eq ["one", "two"]
    end

    it "collapses across an inline node's boundary without losing or doubling the space" do
      doc = TextDocument.from_markdown("**a**   b")
      doc.blocks[0].text.should eq "a b"
      doc.blocks[0].fragments.map(&.text).should eq ["a", " b"]
      doc = TextDocument.from_markdown("a   **b**   c")
      doc.blocks[0].text.should eq "a b c"
      doc = TextDocument.from_markdown("*a*  *b*")
      doc.blocks[0].text.should eq "a b"
    end

    it "collapses inside headings, list items and blockquotes" do
      TextDocument.from_markdown("# head    ing").blocks[0].text.should eq "head ing"
      TextDocument.from_markdown("- item    text").blocks[0].text.should eq "item text"
      TextDocument.from_markdown("- [x]   task    text").blocks[0].text.should eq "task text"
      TextDocument.from_markdown("> quote    text").blocks[0].text.should eq "quote text"
    end

    it "keeps the spaces of a code span" do
      doc = TextDocument.from_markdown("a `x    y` b")
      doc.blocks[0].text.should eq "a x    y b"
      doc.blocks[0].fragments[1].format.code?.should be_true
    end

    it "keeps the spaces of a fenced code block" do
      doc = TextDocument.from_markdown("```\ncode    here\n    indented\n```")
      doc.blocks.map(&.text).should eq ["code    here", "    indented"]
    end

    it "keeps a raw HTML block as written" do
      doc = TextDocument.from_markdown("<pre>\nkeep    me\n</pre>")
      doc.blocks.map(&.text).should eq ["<pre>", "keep    me", "</pre>"]
    end

    it "collapses inside a table cell" do
      doc = TextDocument.from_markdown("| h1 | h2 |\n|---|---|\n| a    b | c\t\td |")
      row = doc.blocks.find! { |b| b.text.includes?("a b") }
      TextTable.split_data_row(row.text).should eq ["a b", "c d"]
    end
  end

  describe "HTML import" do
    it "collapses a paragraph's run of spaces while a pre block keeps its own" do
      doc = TextDocument.from_html("<p>a    b</p><pre>keep    me</pre>")
      doc.blocks[0].text.should eq "a b"
      doc.blocks[1].text.should eq "keep    me"
    end
  end
end
