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
    it "maps headings to heading_level with margin spacing between blocks" do
      doc = md_doc "# Title\n\nBody text"
      doc.blocks[0].block_format.heading_level.should eq 1
      doc.blocks[0].text.should eq "Title"
      # Paragraph spacing = a top margin on the following block, not a
      # literal empty separator block (the margins re-base).
      doc.block_count.should eq 2
      doc.blocks[1].text.should eq "Body text"
      doc.blocks[1].block_format.top_margin.should eq 1
      doc.blocks[0].block_format.top_margin.should eq 0
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

    it "imports lists as TextLists with nesting via the list-format indent" do
      doc = md_doc "- one\n- two\n  - sub"
      doc.blocks[0].text.should eq "one"
      lf = doc.blocks[0].block_format.list_format.not_nil!
      lf.style.disc?.should be_true
      lf.indent.should eq 1
      # Same markdown list = same shared instance.
      doc.blocks[1].block_format.list_format.should be lf
      sub = doc.blocks[2].block_format.list_format.not_nil!
      sub.should_not be lf
      sub.indent.should eq 2
      TextList.new(doc, lf).count.should eq 2
    end

    it "numbers ordered lists structurally and imports task items as a checkbox list" do
      doc = md_doc "1. first\n2. second\n\n- [x] done\n- [ ] todo"
      lf = doc.blocks[0].block_format.list_format.not_nil!
      lf.style.decimal?.should be_true
      list = TextList.new(doc, lf)
      list.marker_text(doc.blocks[1]).should eq "2. "
      # Task items become a shared `Checkbox`-style list; checked state
      # rides on the block, and the marker renders as `[x]`/`[ ]`.
      cf = doc.blocks[2].block_format.list_format.not_nil!
      cf.style.checkbox?.should be_true
      doc.blocks[2].text.should eq "done"
      doc.blocks[2].block_format.checked?.should be_true
      doc.blocks[2].block_format.top_margin.should eq 1
      doc.blocks[3].block_format.list_format.should be cf
      doc.blocks[3].text.should eq "todo"
      doc.blocks[3].block_format.checked?.should be_false
      clist = TextList.new(doc, cf)
      clist.marker_text(doc.blocks[2]).should eq "[x] "
      clist.marker_text(doc.blocks[3]).should eq "[ ] "
      clist.marker_text(doc.blocks[2], Glyphs::Tier::Extended).should eq "[✓] "
    end

    it "imports blockquotes as quote levels and rules as rule blocks" do
      doc = md_doc "> quoted\n>> deeper\n\n---"
      doc.blocks[0].text.should eq "quoted"
      doc.blocks[0].block_format.quote_level.should eq 1
      doc.blocks[1].block_format.quote_level.should eq 2
      doc.blocks[2].block_format.horizontal_rule?.should be_true
      doc.blocks[2].block_format.top_margin.should eq 1
      doc.blocks[2].text.should eq ""
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
