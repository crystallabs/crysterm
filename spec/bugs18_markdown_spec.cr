require "./spec_helper"

include Crysterm

# BUGS18 markdown fixes B18-67..72 — pure model (TextMarkdown / TextHtml).

private def quote_shapes(doc : Crysterm::TextDocument) : Array({String, Int32})
  doc.blocks.map { |b| {b.text, b.block_format.quote_level} }
end

# B18-67 — a GFM-table-shaped paragraph inside a list item must stay item
# content: the table path stamps no list membership, so taking it there
# detached the table from the list, dropped the item's marker and shifted
# ordered numbering on export (B17-28's sibling gap, table flavor).
describe "BUGS18 B18-67 table inside a list item keeps list membership" do
  it "imports a table-shaped ordered item as item content (markdown)" do
    md = "1. a\n2. | x | y |\n   | --- | --- |\n3. b"
    doc = Crysterm::TextDocument.from_markdown(md)

    # Every block is a list member; no block escaped to the table path.
    doc.blocks.size.should eq 3
    doc.blocks.each do |b|
      b.block_format.list_format.should_not be_nil
      b.block_format.table_format.should be_nil
    end

    # Numbering intact on export, and the roundtrip is stable.
    exported = doc.to_markdown
    exported.should contain "3. b"
    round = Crysterm::TextDocument.from_markdown(exported)
    round.blocks.size.should eq 3
    round.blocks[2].text.should eq "b"
    round.to_markdown.should eq exported
  end

  it "keeps a top-level table-shaped paragraph on the table path" do
    doc = Crysterm::TextDocument.from_markdown("| x | y |\n| --- | --- |")
    doc.blocks.any?(&.block_format.table_format).should be_true
  end

  it "materializes the item's member block before the table (html)" do
    html = "<ol><li>a</li><li><table><tr><th>x</th></tr></table></li><li>b</li></ol>"
    doc = Crysterm::TextDocument.from_html(html)

    first_table = doc.blocks.index!(&.block_format.table_format)
    last_table = doc.blocks.rindex!(&.block_format.table_format)
    # Item 2's (empty) member block sits BEFORE its table, not after it.
    doc.blocks[first_table - 1].block_format.list_format.should_not be_nil
    doc.blocks[first_table - 1].text.should eq ""
    # Item 3 follows the table; no fabricated trailing empty item.
    doc.blocks[last_table + 1].block_format.list_format.should_not be_nil
    doc.blocks[last_table + 1].text.should eq "b"
    doc.blocks.size.should eq last_table + 2
  end
end

# B18-68 — import_list was the only structural walk branch missing the
# quote_break? guard: a list entering a quote fabricated a phantom quoted
# blank block ("> " line the source never had) whenever anything was
# emitted before the quote.
describe "BUGS18 B18-68 no phantom quoted blank before a list entering a quote" do
  it "does not fabricate a quoted blank on quote entry" do
    doc = Crysterm::TextDocument.from_markdown("a\n\n> - x")
    quote_shapes(doc).should eq [{"a", 0}, {"x", 1}]
    doc.to_markdown.should eq "a\n\n> - x"
  end

  it "does not fabricate one on nested-quote entry either" do
    doc = Crysterm::TextDocument.from_markdown("> a\n> > - x")
    # No phantom blank at the list's own quote depth (q2); the q1
    # separator the block_quote branch may add before the nested quote is
    # B18-70's accepted normalization, not this bug.
    doc.blocks.none? { |b| b.text.empty? && b.block_format.quote_level == 2 }.should be_true
    exported = doc.to_markdown
    Crysterm::TextDocument.from_markdown(exported).to_markdown.should eq exported
  end

  it "keeps the legitimate quoted blank between same-depth structures" do
    doc = Crysterm::TextDocument.from_markdown("> a\n>\n> - b")
    quote_shapes(doc).should eq [{"a", 1}, {"", 1}, {"b", 1}]
  end
end

# B18-69 — adjacent margin-less plain blocks export with a trailing '\'
# (hard break), but HTML-blockish lines re-import RAW: the backslash became
# a literal character, accumulating on every roundtrip cycle.
describe "BUGS18 B18-69 no hard-break backslash around raw HTML blocks" do
  it "roundtrips a raw HTML block byte-identically over cycles" do
    doc = Crysterm::TextDocument.from_markdown("<div>\ntext\n</div>")
    doc.to_plain_text.should eq "<div>\ntext\n</div>"
    exported = doc.to_markdown
    exported.should_not contain "\\"
    round = Crysterm::TextDocument.from_markdown(exported)
    round.to_plain_text.should eq "<div>\ntext\n</div>"
    round.to_markdown.should eq exported
  end

  it "does not append a literal backslash to a paragraph before an HTML block" do
    doc = Crysterm::TextDocument.from_tags("para\n<div>x</div>")
    exported = doc.to_markdown
    exported.should eq "para\n<div>x</div>"
    round = Crysterm::TextDocument.from_markdown(exported)
    round.blocks[0].text.should eq "para"
    round.blocks[1].text.should eq "<div>x</div>"
  end

  it "keeps hard-break backslashes for non-block-starting tags" do
    # <span>hello matches no HTML block type: the lines must keep their
    # hard breaks or they soft-wrap into one paragraph on re-import.
    md = "a\\\n<span>hello\\\nb"
    doc = Crysterm::TextDocument.from_markdown(md)
    doc.to_markdown.should eq md
  end
end

# B18-70 — the block_quote and html_block walk branches missed the same
# quote_break? guard: the quoted blank line before a nested quote or a
# quoted HTML block was silently dropped (B16-49's remaining siblings).
describe "BUGS18 B18-70 quoted blank kept before nested quote and HTML block" do
  it "keeps the quoted blank before a nested blockquote" do
    doc = Crysterm::TextDocument.from_markdown("> a\n>\n> > b")
    quote_shapes(doc).should eq [{"a", 1}, {"", 1}, {"b", 2}]
    exported = doc.to_markdown
    exported.should eq "> a\n> \n> > b"
    Crysterm::TextDocument.from_markdown(exported).to_markdown.should eq exported
  end

  it "keeps the quoted blank before a quoted HTML block" do
    doc = Crysterm::TextDocument.from_markdown("> para\n>\n> <div>x</div>")
    quote_shapes(doc).should eq [{"para", 1}, {"", 1}, {"<div>x</div>", 1}]
    exported = doc.to_markdown
    Crysterm::TextDocument.from_markdown(exported).to_markdown.should eq exported
  end

  it "still emits nothing when entering a nested quote first" do
    doc = Crysterm::TextDocument.from_markdown("> > b")
    quote_shapes(doc).should eq [{"b", 2}]
  end
end

# B18-71 — the fence branch always emitted a 3-backtick fence, so a code
# line that is itself a ``` run closed the exported fence early on
# re-import, splitting the code block (wrap_code's longest-run+1 rule was
# missing on the block side).
describe "BUGS18 B18-71 fence sized past the longest backtick run in content" do
  it "roundtrips a code block containing a ``` line" do
    doc = Crysterm::TextDocument.from_markdown("````\n```\ncode\n```\n````")
    doc.to_plain_text.should eq "```\ncode\n```"
    exported = doc.to_markdown
    exported.should start_with "````"
    round = Crysterm::TextDocument.from_markdown(exported)
    round.to_plain_text.should eq "```\ncode\n```"
    round.blocks.all?(&.block_format.bg).should be_true
    round.to_markdown.should eq exported
  end

  it "roundtrips the tilde-fence variant" do
    doc = Crysterm::TextDocument.from_markdown("~~~\n```\nx\n~~~")
    doc.to_plain_text.should eq "```\nx"
    round = Crysterm::TextDocument.from_markdown(doc.to_markdown)
    round.to_plain_text.should eq "```\nx"
  end

  it "keeps the plain 3-backtick fence for ordinary content" do
    doc = Crysterm::TextDocument.from_markdown("```\ncode\n```")
    doc.to_markdown.should eq "```\ncode\n```"
  end
end

# B18-72 — escape_md never escaped '&', so entity-shaped plain text
# ("&amp;", "&#65;") decoded — mutating the content — on re-import; same
# for table cells, which escaped only '|'.
describe "BUGS18 B18-72 ampersand escaped so entities don't decode on re-import" do
  it "roundtrips entity-shaped plain text unchanged" do
    doc = Crysterm::TextDocument.new("x &#65; &amp; y")
    round = Crysterm::TextDocument.from_markdown(doc.to_markdown)
    round.to_plain_text.should eq "x &#65; &amp; y"
  end

  it "keeps a backslash-escaped entity stable across cycles" do
    doc = Crysterm::TextDocument.from_markdown("\\&amp;")
    doc.to_plain_text.should eq "&amp;"
    round = Crysterm::TextDocument.from_markdown(doc.to_markdown)
    round.to_plain_text.should eq "&amp;"
  end

  it "escapes '&' in table cells" do
    html = "<table><tr><th>h</th></tr><tr><td>&amp;#65;</td></tr></table>"
    doc = Crysterm::TextDocument.from_html(html)
    doc.to_plain_text.should contain "&#65;"
    round = Crysterm::TextDocument.from_markdown(doc.to_markdown)
    round.to_plain_text.should contain "&#65;"
  end
end
