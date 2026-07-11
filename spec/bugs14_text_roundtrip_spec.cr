require "./spec_helper"

include Crysterm

# BUGS14 T1, T5, T7, T3, T4 — text-interchange round-trip / data-loss and
# ordered-list overflow bugs. Pure model (no window).

describe "BUGS14 text round-trip fixes" do
  # T1 — a loose list-item continuation paragraph must keep its indentation
  # on markdown export so CommonMark does not merge it into the item's line.
  describe "list-item continuation paragraph (T1)" do
    it "keeps an ordered item's continuation paragraph a separate block" do
      md = "1. first\n\n   second para\n2. second"
      doc = TextDocument.from_markdown(md)
      doc.block_count.should eq 3
      back = TextDocument.from_markdown(doc.to_markdown)
      back.block_count.should eq 3
      back.blocks.map(&.text).should eq ["first", "second para", "second"]
    end

    it "keeps an unordered item's continuation paragraph a separate block" do
      md = "- first\n\n  second para\n- second"
      doc = TextDocument.from_markdown(md)
      doc.block_count.should eq 3
      back = TextDocument.from_markdown(doc.to_markdown)
      back.block_count.should eq 3
      back.blocks.map(&.text).should eq ["first", "second para", "second"]
    end
  end

  # T5 — the leading (or every) blank line of a fenced code block must not be
  # dropped from markdown export.
  describe "fenced code block leading blank line (T5)" do
    it "preserves a leading blank line inside a fence" do
      md = "```\n\nx\n```"
      doc = TextDocument.from_markdown(md)
      exported = doc.to_markdown
      exported.should contain "```"
      back = TextDocument.from_markdown(exported)
      # The leading blank line stays a code-bg block inside the fence, so the
      # code block still holds both lines ("" then "x").
      code = back.blocks.select(&.block_format.bg)
      code.map(&.text).should eq ["", "x"]
    end

    it "does not vanish an all-blank fenced code block" do
      md = "text\n\n```\n\n\n```\n\nmore"
      doc = TextDocument.from_markdown(md)
      exported = doc.to_markdown
      exported.should contain "```"
      back = TextDocument.from_markdown(exported)
      back.blocks.any?(&.block_format.bg).should be_true
      back.to_plain_text.should contain "text"
      back.to_plain_text.should contain "more"
    end

    it "still does not fence a lone empty styled block (T19 preserved)" do
      blocks = [
        TextBlock.new([TextFragment.new("x", TextCharFormat.default)]),
        TextBlock.new([] of TextFragment, TextBlockFormat.new(bg: TextTheme.default.code_bg)),
        TextBlock.new([TextFragment.new("y", TextCharFormat.default)]),
      ]
      TextMarkdown.generate(blocks).should_not contain "```"
    end
  end

  # T7 — an unbounded ordered-list `start` from HTML/tags must be clamped at
  # import so numbered marker rendering / export never overflows Int32.
  describe "ordered-list start overflow (T7)" do
    it "clamps a huge <ol start> and exports without raising" do
      doc = TextDocument.from_html(%(<ol start="2147483647"><li>a</li><li>b</li></ol>))
      lf = doc.blocks[0].block_format.list_format.not_nil!
      lf.start.should eq 1_000_000
      md = doc.to_markdown
      md.should contain "1000000"
      md.should contain "1000001"
    end

    it "renders an imported huge-start list marker without overflow" do
      doc = TextDocument.from_html(%(<ol start="2147483647"><li>a</li><li>b</li></ol>))
      lf = doc.blocks[0].block_format.list_format.not_nil!
      # marker() is the render primitive — must not raise for item >= 1.
      lf.marker(0).should eq "1000000. "
      lf.marker(1).should eq "1000001. "
    end

    it "clamps a huge ls- tag start" do
      tags = "{!block;list-decimal;ls-2000000000}a\n{!block;list-decimal;ls-2000000000}b"
      doc = TextDocument.from_tags(tags)
      lf = doc.blocks[0].block_format.list_format.not_nil!
      lf.start.should eq 1_000_000
      doc.to_markdown # must not raise
    end
  end

  # T3 — a list item's `white-space:pre-wrap` collapse flag must reach its
  # first block on HTML import, so TABs inside <li> survive the round-trip.
  describe "list item pre-wrap collapse flag (T3)" do
    it "keeps a TAB inside a list item across an HTML round-trip" do
      lf = TextListFormat.new(style: :disc, indent: 1)
      block = TextBlock.new([TextFragment.new("a\tb", TextCharFormat.default)],
        TextBlockFormat.new(list_format: lf))
      html = TextHtml.generate([block])
      html.should contain "white-space:pre-wrap"
      back = TextDocument.from_html(html)
      back.blocks[0].text.should eq "a\tb"
      back.blocks[0].block_format.list_format.should_not be_nil
    end

    it "keeps multiple spaces inside a list item across an HTML round-trip" do
      lf = TextListFormat.new(style: :disc, indent: 1)
      block = TextBlock.new([TextFragment.new("a  b", TextCharFormat.default)],
        TextBlockFormat.new(list_format: lf))
      back = TextDocument.from_html(TextHtml.generate([block]))
      back.blocks[0].text.should eq "a  b"
    end
  end

  # T4 — TextTable#insert_column must not raise IndexError when the
  # alignments array is shorter than the column count (typical after import).
  describe "insert_column with short alignments array (T4)" do
    it "inserts a column into an HTML-imported partial-alignment table" do
      doc = TextDocument.from_html(
        %(<table><tr><td style="text-align:right">a</td><td>b</td><td>c</td></tr></table>))
      tb = TextTable.new(doc, doc.blocks[0].block_format.table_format.not_nil!)
      tb.columns.should eq 3
      tb.format.alignments.not_nil!.size.should be < 3
      tb.insert_column(2).should be_true # must not raise IndexError
    end
  end
end
