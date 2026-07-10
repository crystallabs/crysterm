require "./spec_helper"

include Crysterm

# BUGS13 T1, T2, T3, T5, T18, T19, T28 — markdown block-structure
# round-trip bugs (importer state leaks, exporter separators/fences).

describe "BUGS13 markdown block structure" do
  # T1 — an empty list item never opens a block; its pending marker must
  # not leak onto the next unrelated block.
  describe "empty list item (T1)" do
    it "does not attach the next paragraph to the list" do
      doc = TextDocument.from_markdown("- a\n-\n\nplain")
      doc.blocks[0].text.should eq "a"
      doc.blocks[0].block_format.list_format.should_not be_nil
      last = doc.blocks.last
      last.text.should eq "plain"
      last.block_format.list_format.should be_nil
    end

    it "does not leak a checked task marker either" do
      doc = TextDocument.from_markdown("- [x]\n\nplain")
      last = doc.blocks.last
      last.text.should eq "plain"
      last.block_format.list_format.should be_nil
      last.block_format.checked?.should be_false
    end
  end

  # T2 — a fenced code block inside a blockquote keeps its `> ` prefixes.
  describe "fence inside blockquote (T2)" do
    it "round-trips a quoted fence" do
      md = "> ```\n> code\n> ```"
      doc = TextDocument.from_markdown(md)
      doc.blocks[0].block_format.quote_level.should eq 1
      doc.to_markdown.should eq md
    end

    it "keeps quote level and code flag through a full cycle" do
      doc = TextDocument.from_markdown(TextDocument.from_markdown("> ```\n> a\n> b\n> ```").to_markdown)
      doc.block_count.should eq 2
      doc.blocks.each do |b|
        b.block_format.quote_level.should eq 1
        b.block_format.bg.should eq TextTheme.default.code_bg
      end
      doc.blocks.map(&.text).should eq ["a", "b"]
    end
  end

  # T3 — a nested list indents to the parent item's content column (3 for
  # "1. "), not a constant 2.
  describe "nested list indent (T3)" do
    it "indents a sublist under an ordered parent to the content column" do
      md = "1. first\n   - sub"
      TextDocument.from_markdown(md).to_markdown.should eq md
    end

    it "keeps the sublist nested across a full cycle" do
      doc = TextDocument.from_markdown(TextDocument.from_markdown("1. first\n   - sub").to_markdown)
      doc.blocks[0].block_format.list_format.not_nil!.indent.should eq 1
      doc.blocks[1].block_format.list_format.not_nil!.indent.should eq 2
      doc.blocks[1].text.should eq "sub"
    end

    it "keeps a sublist under a task item nested (content column is after the bullet)" do
      md = "- [x] a\n  - b"
      doc = TextDocument.from_markdown(TextDocument.from_markdown(md).to_markdown)
      doc.blocks[1].block_format.list_format.not_nil!.indent.should eq 2
      doc.blocks[1].text.should eq "b"
    end
  end

  # T5 — adjacent body blocks with no separating margin export as a hard
  # break, not a soft-wrapping bare newline.
  describe "margin-less block boundary (T5)" do
    it "exports a hard break so the blocks survive re-import" do
      doc = TextDocument.new("a\nb")
      md = doc.to_markdown
      md.should eq "a\\\nb"
      back = TextDocument.from_markdown(md)
      back.block_count.should eq 2
      back.to_plain_text.should eq "a\nb"
    end

    it "hard-breaks inside a quote too" do
      doc = TextDocument.from_markdown("> a\\\n> b")
      doc.block_count.should eq 2
      doc.to_markdown.should eq "> a\\\n> b"
    end

    it "does not add a backslash when a margin separates the blocks" do
      doc = TextDocument.from_markdown("a\n\nb")
      doc.to_markdown.should eq "a\n\nb"
    end
  end

  # T18 — two fences separated by a blank line stay two fences.
  describe "adjacent fenced code blocks (T18)" do
    it "round-trips two fences separated by a blank line" do
      md = "```\na\n```\n\n```\nb\n```"
      TextDocument.from_markdown(md).to_markdown.should eq md
    end
  end

  # T19 — an empty styled block must not open a code fence (the all-code
  # fragment test is vacuous on an empty block).
  describe "empty bg block is not a fence (T19)" do
    it "does not classify an empty non-code block as a fence row" do
      blocks = [
        TextBlock.new([TextFragment.new("x", TextCharFormat.default)]),
        TextBlock.new([] of TextFragment, TextBlockFormat.new(bg: TextTheme.default.code_bg)),
        TextBlock.new([TextFragment.new("y", TextCharFormat.default)]),
      ]
      TextMarkdown.generate(blocks).should_not contain "```"
    end

    it "still keeps blank interior fence lines inside a fence" do
      md = "```\nline1\n\nline3\n```"
      TextDocument.from_markdown(md).to_markdown.should eq md
    end
  end

  # T28 — a heading/fence/HR inside a list item must not push a spurious
  # top-level empty block.
  describe "structure inside a list item (T28)" do
    it "imports a heading in an item without a phantom empty block" do
      doc = TextDocument.from_markdown("- a\n  # h")
      doc.block_count.should eq 2
      doc.blocks.map(&.text).should eq ["a", "h"]
      doc.blocks[1].block_format.heading_level.should eq 1
    end

    it "imports a fence in an item without a phantom empty block" do
      doc = TextDocument.from_markdown("- a\n  ```\n  c\n  ```")
      doc.blocks.map(&.text).should eq ["a", "c"]
    end

    it "keeps the quote-interior separator behavior" do
      # Inside a quote the blank line stays a literal quote-level block
      # (it renders the quote bar).
      doc = TextDocument.from_markdown("> a\n>\n> # h")
      doc.blocks.map(&.text).should eq ["a", "", "h"]
      doc.blocks[1].block_format.quote_level.should eq 1
    end
  end
end
