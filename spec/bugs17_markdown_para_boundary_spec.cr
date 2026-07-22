require "./spec_helper"

include Crysterm

# Regression spec for BUGS17 B17-45 — the markdown Exporter emitted a bare
# newline (no blank line) between a plain paragraph and a following empty list
# item or a table. Since neither can interrupt a paragraph under CommonMark/GFM,
# re-import merged the marker text into the paragraph (empty item) or swallowed
# the table into the paragraph. The blocks come from the HTML importer, which
# adds no margin, so nothing else forces the separator.
describe "BUGS17 markdown paragraph->structure boundary" do
  # An empty ordered item after a paragraph renders as "1. "; without a blank
  # line the marker lazily merged into the paragraph (the number IS 1, so the
  # numbered-!=1 guard misses it). Assert on the paragraph text — the importer
  # drops the empty item, so block_count stays 1 even after the fix.
  it "keeps an empty ordered item from corrupting the preceding paragraph" do
    doc = TextDocument.from_html("<p>para</p><ol><li></li></ol>")
    round = TextDocument.from_markdown(doc.to_markdown)
    round.blocks[0].text.should eq "para"
  end

  # A table directly after a plain paragraph was swallowed into the paragraph
  # (the GFM detector needs the table to begin its own block). Assert the table
  # survives and the paragraph remains a standalone non-table block.
  it "keeps a table after a paragraph from being swallowed" do
    doc = TextDocument.from_html("<p>para</p><table><tr><th>a</th></tr></table>")
    round = TextDocument.from_markdown(doc.to_markdown)
    round.blocks.any?(&.block_format.table_format).should be_true
    round.blocks.any? { |b| b.block_format.table_format.nil? && b.text == "para" }.should be_true
  end
end
