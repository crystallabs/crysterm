require "./spec_helper"

include Crysterm

# BUGS18 round 2/3 text-layer fixes:
#   B18-73 — HTML importer's `collect_text` dropped `<br>`, merging lines with
#            no separator inside `<pre>` and table cells.
#   B18-74 — `SyntaxHighlighter#rehighlight_block` didn't cascade a state
#            change to following blocks the way the edit path does.
#   B18-75 — `TextTable.sanitize_build_cell` didn't strip `\n` like its
#            editing-path twin `sanitize_cell`, letting a block-separator
#            character leak into a rendered table block.
#   B18-76 — Negative row/column indexes wrapped via Array negative indexing
#            instead of returning nil from the table's read/cursor accessors.
#   B18-77 — HTML importer's `discard_virgin` re-donation dropped the `<li>`'s
#            own block styles (alignment, pre-wrap collapse) when the item
#            content was nested inside an extra wrapper element.

describe "B18-73 <br> inside <pre> and table cells" do
  it "splits a <pre> block into two lines instead of merging them" do
    doc = TextDocument.from_html("<pre>a<br>b</pre>")
    code_blocks = doc.blocks.select(&.block_format.bg)
    code_blocks.map(&.text).should eq ["a", "b"]
  end

  it "collapses <br> to a space inside a table cell" do
    doc = TextDocument.from_html("<table><tr><th>h1</th><th>h2</th></tr><tr><td>a<br>b</td><td>c</td></tr></table>")
    tf = doc.blocks.find!(&.block_format.table_format).block_format.table_format.not_nil!
    t = TextTable.new(doc, tf)
    t.cell_text(1, 0).should eq "a b"
  end
end

private class ToggleCommentHighlighter < Crysterm::SyntaxHighlighter
  RED = Crysterm::TextCharFormat.new(fg: 0xFF0000)
  property enabled = true

  def highlight_block(text)
    inside = previous_block_state == 1
    opens = enabled && text.starts_with?("/*")
    closes = text.includes?("*/")
    if inside || opens
      set_format(0, text.size, RED)
    end
    self.current_block_state = (opens || inside) && !closes ? 1 : 0
  end
end

describe "B18-74 rehighlight_block cascades to following blocks" do
  it "clears stale overlays/state on followers when the target block's state changes" do
    doc = TextDocument.new("/* open\nmiddle\nlast")
    hl = ToggleCommentHighlighter.new(doc)

    doc.blocks.map(&.user_state).should eq [1, 1, 1]
    doc.blocks.each(&.additional_formats.should_not(be_nil))

    hl.enabled = false
    hl.rehighlight_block(doc.blocks[0])

    doc.blocks.map(&.user_state).should eq [0, 0, 0]
    doc.blocks.each(&.additional_formats.should(be_nil))
  end

  it "stops cascading once a block's state stops changing" do
    doc = TextDocument.new("/* open\nmiddle\nlast")
    hl = ToggleCommentHighlighter.new(doc)
    doc.blocks.map(&.user_state).should eq [1, 1, 1]

    # Re-highlighting the last block alone (no config change) must not
    # touch the others and must terminate after one block.
    hl.rehighlight_block(doc.blocks[2])
    doc.blocks.map(&.user_state).should eq [1, 1, 1]
  end
end

describe "B18-75 sanitize_build_cell strips newlines like sanitize_cell" do
  it "never emits a block containing '\\n' from TextTable.build" do
    blocks = TextTable.build(["h1", "h2"], [["line1\nline2", "b"]])
    blocks.each(&.text.should_not(contain('\n')))
  end

  it "round-trips through markdown export without splitting the row" do
    doc = TextDocument.new
    blocks = TextTable.build(["h1", "h2"], [["line1\nline2", "b"]])
    doc.insert_fragment(0, TextDocumentFragment.new(blocks))
    doc.to_plain_text.lines.size.should eq doc.blocks.size
    doc.to_markdown.should contain("line1 line2")
  end
end

describe "B18-76 negative row/column indexes return nil instead of wrapping" do
  it "returns nil (not the last row) for a negative row" do
    doc = TextDocument.from_markdown("| h1 | h2 |\n| --- | --- |\n| a | b |\n| c | d |")
    tf = doc.blocks.find!(&.block_format.table_format).block_format.table_format.not_nil!
    t = TextTable.new(doc, tf)

    t.row_block(-1).should be_nil
    t.cell_text(-1, 0).should be_nil
    t.cell_text_range(-1, 0).should be_nil
    t.cell_cursor(-1, 0).should be_nil
  end

  it "returns nil (not a wrapped column) for a negative column" do
    doc = TextDocument.from_markdown("| h1 | h2 |\n| --- | --- |\n| a | b |\n| c | d |")
    tf = doc.blocks.find!(&.block_format.table_format).block_format.table_format.not_nil!
    t = TextTable.new(doc, tf)

    t.cell_text(0, -1).should be_nil
    t.cell_text_range(0, -2).should be_nil
    t.cell_text_range(0, -99).should be_nil
  end
end

describe "B18-77 li styles survive a wrapper element around the item content" do
  it "keeps the <li>'s alignment when its content is wrapped in a <div>" do
    doc = TextDocument.from_html(%(<ul><li style="text-align:center"><div><p>x</p></div></li></ul>))
    doc.blocks[0].block_format.alignment.should eq Tput::AlignFlag::HCenter
    doc.blocks[0].block_format.list_format.should_not be_nil
  end

  it "keeps the <li>'s pre-wrap whitespace collapse behavior through a wrapper" do
    doc = TextDocument.from_html(%(<ul><li style="white-space:pre-wrap"><div><p>a  b</p></div></li></ul>))
    doc.blocks[0].text.should eq "a  b"
  end
end
