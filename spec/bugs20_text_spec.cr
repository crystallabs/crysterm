require "./spec_helper"

private def md_doc(text : String) : Crysterm::TextDocument
  Crysterm::TextDocument.from_markdown(text)
end

describe "TextCursor word bounds with no word before the position" do
  it "leaves the cursor in place on a first block of separators only" do
    doc = Crysterm::TextDocument.new("  ")
    c = doc.cursor(2)
    c.select :word_under_cursor
    c.selection?.should be_false
    c.position.should eq 2
  end

  it "does not report a move to the start of a word that is not there" do
    doc = Crysterm::TextDocument.new("- [ ] x")
    c = doc.cursor(2)
    c.move_position(Crysterm::TextCursor::MoveOperation::StartOfWord).should be_false
    c.position.should eq 2
  end

  it "still takes the word before the position in the first block" do
    doc = Crysterm::TextDocument.new("foo  ")
    c = doc.cursor(5)
    c.select :word_under_cursor
    c.selected_text.should eq "foo"
  end
end

describe "Markdown bare URL trimming" do
  it "keeps a balanced closing parenthesis and sheds the rest" do
    doc = md_doc("see https://x.io/a(b)). done")
    doc.blocks[0].fragments.compact_map(&.format.anchor_href).should eq ["https://x.io/a(b)"]
  end

  it "sheds a long run of closing parentheses and punctuation" do
    doc = md_doc("https://x.io/a#{")" * 2000}#{"." * 2000}")
    doc.blocks[0].fragments.compact_map(&.format.anchor_href).should eq ["https://x.io/a"]
  end

  it "reads an entity-like tail as outside the URL" do
    # An escaped `\&` keeps `&amp;` literal text.
    doc = md_doc("https://x.io/a\\&amp; z")
    doc.blocks[0].fragments.compact_map(&.format.anchor_href).should eq ["https://x.io/a"]
    doc.to_plain_text.should eq "https://x.io/a&amp; z"
  end
end

describe "GFM delimiter row detection" do
  it "accepts delimiter rows and rejects other second lines" do
    Crysterm::TextTable.gfm_table?("| a | b |\n|:--|--:|").should be_true
    Crysterm::TextTable.gfm_table?("a | b\n --- | --- ").should be_true
    Crysterm::TextTable.gfm_table?("a | b\n:: | ::").should be_false
    Crysterm::TextTable.gfm_table?("a | b\n--- | -x-").should be_false
  end

  it "rejects a long run of dashes ending in text without backtracking over it" do
    Crysterm::TextTable.gfm_table?("a | b\n#{"-" * 20_000}x").should be_false
  end

  it "imports a pipe line over a long dash run ending in text as a paragraph" do
    doc = md_doc("a | b\n#{"-" * 3000}x")
    doc.block_count.should eq 1
    doc.blocks[0].block_format.table_format.nil?.should be_true
    doc.to_plain_text.should end_with "-x"
  end

  it "still imports a table whose delimiter row sits behind a quote prefix" do
    doc = md_doc("> | a | b |\n> |---|---|\n> | 1 | 2 |")
    doc.blocks.any? { |b| !b.block_format.table_format.nil? }.should be_true
  end
end

describe "TextTags tokenizing of text with non-ASCII characters" do
  it "reads tags, escapes, literal braces and links around multi-byte text" do
    doc = Crysterm::TextDocument.from_tags("é{bold}ü{/bold}{open}ž{close}{escape}{ñ}{/escape}{link=http://x/ö}λ{/link}")
    doc.to_plain_text.should eq "éü{ž}{ñ}λ"
    frags = doc.blocks[0].fragments
    frags.select(&.format.bold?).map(&.text).should eq ["ü"]
    frags.select(&.format.anchor?).map(&.text).should eq ["λ"]
    frags.compact_map(&.format.anchor_href).should eq ["http://x/ö"]
  end

  it "drops lone braces between multi-byte characters" do
    Crysterm::TextDocument.from_tags("ž{ ž}ž").to_plain_text.should eq "ž žž"
    Crysterm::TextDocument.from_tags("ž{link=ž").to_plain_text.should eq "žlink=ž"
  end

  it "keeps an unterminated escape's remainder verbatim" do
    Crysterm::TextDocument.from_tags("ž{escape}{bold}ž").to_plain_text.should eq "ž{bold}ž"
  end
end

describe "TextTags numeric block props out of range" do
  it "drops a quote level too large to lay out" do
    doc = Crysterm::TextDocument.from_tags("{!block;q-2000000000}x")
    doc.blocks[0].block_format.quote_level.should eq 0
    doc.to_markdown.should eq "x"
  end

  it "drops an indent and margins too large to lay out" do
    doc = Crysterm::TextDocument.from_tags("{!block;q-1;indent-2147483647;mt-5000;mb-5000}x")
    bf = doc.blocks[0].block_format
    bf.indent.should eq 0
    bf.top_margin.should eq 0
    bf.bottom_margin.should eq 0
    bf.leading_inset_cells.should eq 2
  end

  it "keeps a list at its default level for a level of 0 or one too deep" do
    doc = Crysterm::TextDocument.from_tags("{!block;list-disc;li-0}x")
    doc.blocks[0].block_format.list_format.try(&.indent).should eq 1
    doc.to_html.should contain "<li>"
    doc = Crysterm::TextDocument.from_tags("{!block;list-disc;li-1000000000}x")
    doc.blocks[0].block_format.list_format.try(&.indent).should eq 1
    doc.to_markdown.should eq "- x"
  end

  it "drops a table of too many columns" do
    doc = Crysterm::TextDocument.from_tags("{!block;tbl-2000000000}x")
    doc.blocks[0].block_format.table_format.nil?.should be_true
  end

  it "keeps values within range" do
    doc = Crysterm::TextDocument.from_tags("{!block;q-2;indent-4;mt-1;list-decimal;li-3}x")
    bf = doc.blocks[0].block_format
    bf.quote_level.should eq 2
    bf.indent.should eq 4
    bf.top_margin.should eq 1
    bf.list_format.try(&.indent).should eq 3
  end
end

describe "Importing a source nested deeper than the importers walk" do
  it "imports Markdown quotes nested past the limit as plain text" do
    source = "#{">" * 600} x"
    doc = md_doc(source)
    doc.block_count.should eq 1
    doc.blocks[0].block_format.quote_level.should eq 0
    doc.to_plain_text.should eq source
  end

  it "stamps the plain lines of a Markdown source nested too deep" do
    doc = md_doc("first\n\n#{">" * 600} x\n")
    doc.blocks.map(&.text).should eq ["first", "", "#{">" * 600} x"]
    doc.blocks.map(&.source_line).should eq [1, 2, 3]
  end

  it "imports Markdown quotes nested within the limit as quotes" do
    doc = md_doc("#{">" * 100} x")
    doc.to_plain_text.should eq "x"
    doc.blocks[0].block_format.quote_level.should eq 100
  end

  it "imports HTML elements nested past the limit as their text" do
    doc = Crysterm::TextDocument.from_html("<style>p{}</style>#{"<div>" * 600}deep  <b>text</b>#{"</div>" * 600}")
    doc.block_count.should eq 1
    doc.to_plain_text.should eq "deep text"
  end

  it "imports HTML elements nested within the limit with their formats" do
    doc = Crysterm::TextDocument.from_html("#{"<div>" * 50}<b>x</b>#{"</div>" * 50}")
    doc.to_plain_text.should eq "x"
    doc.blocks[0].fragments[0].format.bold?.should be_true
  end
end
