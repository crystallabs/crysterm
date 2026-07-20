require "./spec_helper"

include Crysterm

# B16-48: backward regex find must not return nil when the only candidate
# match straddles `from` — it must find the last match ending at or before
# `from`, per the documented contract (text_document.cr:381-382).
#
# B16-49: markdown import must preserve the blank line between two
# paragraphs inside a blockquote as a quote-level separator block, matching
# the heading/code/thematic-break branches (import_paragraph must gate on
# `top_level? || @quote_depth > 0`, not `top_level?` alone).

describe "Crysterm::TextDocument#find (B16-48)" do
  it "finds a backward regex match that straddles from, inside a digit run" do
    doc = TextDocument.new("abc123456")
    c = doc.find(/\d+/, from: 5, flags: :backward).not_nil!
    c.selection_start.should eq 3
    c.selected_text.should eq "12"
  end

  it "finds a backward regex match that straddles from, inside a letter run" do
    doc = TextDocument.new("aaa")
    c = doc.find(/a+/, 2, flags: :backward).not_nil!
    c.selection_start.should eq 0
    c.selected_text.should eq "aa"
  end

  it "still finds a match ending exactly at from (pinned regression)" do
    doc = TextDocument.new("a1 b22 c333")
    c = doc.find(/\d+/, from: doc.size, flags: :backward).not_nil!
    c.selected_text.should eq "333"
    c = doc.find(/\d+/, from: 6, flags: :backward).not_nil!
    c.selected_text.should eq "22"
  end

  it "still rejects a WholeWords match ending at from when a word char follows in the document" do
    doc = TextDocument.new("catalog")
    # "cat" ends at 3, but "catalog" continues past from=3 with a word char,
    # so WholeWords must reject it even though the truncated prefix alone
    # would look like a whole word.
    doc.find(/cat/, from: 3, flags: TextDocument::FindFlag::Backward | TextDocument::FindFlag::WholeWords).should be_nil
  end
end

describe Crysterm::TextMarkdown do
  describe "paragraph separator inside a blockquote (B16-49)" do
    it "keeps a blank-line-separated quote-level separator block between two paragraphs in a quote" do
      doc = TextDocument.from_markdown("> a\n>\n> b")
      shapes = doc.blocks.map { |b| {b.text, b.block_format.quote_level} }
      shapes.should eq [{"a", 1}, {"", 1}, {"b", 1}]
    end

    it "round-trips the paragraph break through to_markdown" do
      doc = TextDocument.from_markdown("> a\n>\n> b")
      md = doc.to_markdown
      round = TextDocument.from_markdown(md)
      round.blocks.map(&.text).should eq ["a", "", "b"]
      round.blocks.map(&.block_format.quote_level).should eq [1, 1, 1]
    end
  end
end
