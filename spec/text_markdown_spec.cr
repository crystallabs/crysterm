require "./spec_helper"

include Crysterm

# Markdown interchange (`TextMarkdown`, TEXTEDIT.md Phase 3). Pure model.
# Import walks the markd AST into blocks/fragments; export keys on semantic
# properties (heading_level, code flag, anchors), so the theme colors the
# importer applies don't affect round-trips.

private def md_doc(md : String) : Crysterm::TextDocument
  Crysterm::TextDocument.from_markdown(md)
end

describe Crysterm::TextMarkdown do
  describe ".parse" do
    it "maps headings to heading_level with a separator between blocks" do
      doc = md_doc "# Title\n\nBody text"
      doc.blocks[0].block_format.heading_level.should eq 1
      doc.blocks[0].text.should eq "Title"
      doc.blocks[1].text.should eq "" # paragraph spacing = empty separator block
      doc.blocks[2].text.should eq "Body text"
    end

    it "maps emphasis to char formats" do
      doc = md_doc "plain **bold** *italic* ~~gone~~"
      f = doc.blocks[0].fragments
      f[0].format.bold?.should be_false
      f[1].format.bold?.should be_true
      f[1].text.should eq "bold"
      f[3].format.italic?.should be_true
      f[5].format.strike?.should be_true
      f[5].text.should eq "gone"
    end

    it "marks inline code semantically and visually" do
      doc = md_doc "run `crystal spec` now"
      code = doc.blocks[0].fragments[1]
      code.text.should eq "crystal spec"
      code.format.code?.should be_true
      code.format.bg.should eq TextTheme.default.code_bg
    end

    it "maps links to anchors" do
      doc = md_doc "see [docs](https://example.com)"
      link = doc.blocks[0].fragments[1]
      link.text.should eq "docs"
      link.format.anchor_href.should eq "https://example.com"
    end

    it "renders lists as marker prefixes with nesting indent" do
      doc = md_doc "- one\n- two\n  - sub"
      doc.blocks[0].text.should eq "• one"
      doc.blocks[1].text.should eq "• two"
      doc.blocks[2].text.should eq "  • sub"
    end

    it "numbers ordered lists and marks task items" do
      doc = md_doc "1. first\n2. second\n\n- [x] done\n- [ ] todo"
      doc.blocks[0].text.should eq "1. first"
      doc.blocks[1].text.should eq "2. second"
      doc.blocks[3].text.should eq "☑ done"
      doc.blocks[4].text.should eq "☐ todo"
    end

    it "prefixes blockquotes and emits rule blocks" do
      doc = md_doc "> quoted\n\n---"
      doc.blocks[0].text.should eq "#{TextMarkdown.quote_prefix}quoted"
      doc.blocks[2].text.should eq TextMarkdown.rule_text
    end

    it "imports fenced code as code-bg blocks, one per line" do
      doc = md_doc "```\nline1\n\nline3\n```"
      (0..2).each do |i|
        doc.blocks[i].block_format.bg.should eq TextTheme.default.code_bg
      end
      doc.blocks[0].text.should eq "line1"
      doc.blocks[1].text.should eq ""
      doc.blocks[2].text.should eq "line3"
      doc.blocks[0].fragments[0].format.code?.should be_true
    end

    it "turns soft breaks into spaces and hard breaks into new blocks" do
      md_doc("a\nb").to_plain_text.should eq "a b"
      md_doc("a  \nb").to_plain_text.should eq "a\nb"
    end
  end

  describe ".generate" do
    it "round-trips a document of common constructs" do
      md = <<-MD
        # Title

        plain **bold** *italic* and `code` with [a link](https://x.io)

        - one
        - two
          - sub

        1. first
        2. second

        > quoted

        ---

        ```
        fenced code
        two lines
        ```
        MD

      doc = md_doc md
      regenerated = doc.to_markdown
      regenerated.should eq md

      # And the regenerated form imports identically.
      TextDocument.from_markdown(regenerated).to_plain_text.should eq doc.to_plain_text
    end

    it "round-trips task lists" do
      md = "- [x] done\n- [ ] todo"
      md_doc(md).to_markdown.should eq md
    end

    it "escapes markdown specials in plain text" do
      doc = TextDocument.new("2 * 3 [x]")
      md = doc.to_markdown
      TextDocument.from_markdown(md).to_plain_text.should eq "2 * 3 [x]"
    end

    it "exports combined bold italic" do
      doc = TextDocument.new("x")
      doc.apply_char_format(0, 1, TextCharFormat.new(bold: true, italic: true))
      doc.to_markdown.should eq "***x***"
    end
  end
end
