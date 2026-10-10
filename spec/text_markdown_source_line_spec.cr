require "./spec_helper"

include Crysterm

# `TextBlock#source_line`: the Markdown importer stamps every block it builds
# from a source line with that (1-based) line — the hook an editor/preview
# pair syncs its carets on. Generated blocks (separators, table borders) get
# none.

private def md_doc(md : String) : Crysterm::TextDocument
  Crysterm::TextDocument.from_markdown(md)
end

describe "TextMarkdown source lines" do
  it "stamps every imported block with the source line it came from" do
    md = <<-MD
      # Title

      First paragraph
      continues here.\\
      Hard break above.

      - one
      - two
        more of two

      > quoted

      ```
      code a
      code b
      ```

      ---

      | h1 | h2 |
      | -- | -- |
      | a  | b  |
      | c  | d  |

      <div>
      html
      </div>
      MD
    doc = md_doc md
    lines = doc.blocks.map { |b| {b.text, b.source_line} }
    lines.should contain({"Title", 1})
    # A soft-wrapped paragraph is one block from its first line; the
    # hard-broken continuation is its own block on its own line.
    lines.should contain({"First paragraph continues here.", 3})
    lines.should contain({"Hard break above.", 5})
    lines.should contain({"one", 7})
    lines.should contain({"two more of two", 8})
    lines.should contain({"quoted", 11})
    # Fenced code: the content lines, not the fence.
    lines.should contain({"code a", 14})
    lines.should contain({"code b", 15})
    doc.blocks.find!(&.block_format.horizontal_rule?).source_line.should eq 18
    # Table data rows: the header, then the body from the third line on
    # (the delimiter row renders as no block); border rows carry none.
    rows = doc.blocks.select { |b| TextTable.data_row?(b.text) }.map(&.source_line)
    rows.should eq [20, 22, 23]
    doc.blocks.select { |b| b.block_format.table_format && !TextTable.data_row?(b.text) }
      .all? { |b| b.source_line.nil? }.should be_true
    lines.should contain({"<div>", 25})
    lines.should contain({"html", 26})
    lines.should contain({"</div>", 27})
  end

  it "leaves generated blocks without one and keeps it across a clone" do
    doc = md_doc "> a\n>\n> b\n"
    doc.blocks.map(&.source_line).should eq [1, nil, 3]
    doc.blocks[0].clone.source_line.should eq 1
    doc.blocks[0].split(0).source_line.should be_nil
  end

  it "numbers indented code from its first line" do
    doc = md_doc "para\n\n    code\n    more\n"
    doc.blocks.map { |b| {b.text, b.source_line} }.should eq [
      {"para", 1}, {"code", 3}, {"more", 4},
    ]
  end
end
