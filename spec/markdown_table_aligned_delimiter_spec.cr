require "./spec_helper"

include Crysterm

# A GFM delimiter row with alignment colons (`|:---:|`) must still make a
# table. markd splits inline text at `:` (an emoji/autolink special), so each
# `|` of such a row became its own text node, which the importer used to read
# as a backslash-escaped `\|` and so demoted the whole table to a paragraph.
# Escapes are now read from the source (`Importer#escaped_pipes`) instead.

private def table_format_of(d : TextDocument) : TextTableFormat
  d.blocks.find!(&.block_format.table_format).block_format.table_format.not_nil!
end

describe "Markdown table with aligned delimiter row" do
  it "imports a center/left/right-aligned table as a table" do
    d = TextDocument.from_markdown("| A | B | C |\n|:-:|:--|--:|\n| s | t | u |")
    tf = table_format_of(d)
    tf.columns.should eq 3
    tf.alignments.should eq [Tput::AlignFlag::HCenter, Tput::AlignFlag::Left, Tput::AlignFlag::Right]
  end

  it "keeps an escaped pipe as cell content in an aligned table" do
    d = TextDocument.from_markdown("| A | B |\n|:-:|:-:|\n| x \\| y | z |")
    table_format_of(d).columns.should eq 2
    d.to_plain_text.should contain "x | y"
  end

  it "ignores a pipe inside a link destination when restoring escapes" do
    d = TextDocument.from_markdown("| A | B |\n|---|---|\n| [t](http://x/a|b) | c \\| d |")
    table_format_of(d).columns.should eq 2
    d.to_plain_text.should contain "c | d"
  end

  it "reads an unescaped pipe beside inline markup as a cell boundary" do
    d = TextDocument.from_markdown("|A|B|\n|:-:|:-:|\n|*s*|t|")
    table_format_of(d).columns.should eq 2
  end

  it "round-trips an aligned table through markdown" do
    d = TextDocument.from_markdown("| A | B | C |\n|:-:|:--|--:|\n| s | t | u |")
    again = TextDocument.from_markdown(d.to_markdown)
    again.to_plain_text.should eq d.to_plain_text
    table_format_of(again).alignments.should eq table_format_of(d).alignments
  end
end
