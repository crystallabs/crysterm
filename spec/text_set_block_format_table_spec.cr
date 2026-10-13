require "./spec_helper"

include Crysterm

describe "TextCursor#set_block_format on table blocks" do
  md = "para\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nend\n"

  it "keeps a row in its table" do
    doc = TextDocument.from_markdown(md)
    bi = doc.blocks.index! { |b| b.text.includes?("1") && b.block_format.table_format }
    tf = doc.blocks[bi].block_format.table_format
    pos = doc.block_position(bi)
    doc.cursor(pos, pos).set_block_format(TextBlockFormat.new(alignment: Tput::AlignFlag::HCenter))
    doc.blocks[bi].block_format.table_format.should be(tf)
    doc.blocks[bi].block_format.alignment.should eq(Tput::AlignFlag::HCenter)
    doc.to_markdown.should contain("| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n")
  end

  it "formats a selection over text and a table in one undo step" do
    doc = TextDocument.from_markdown(md)
    before = doc.to_markdown
    doc.cursor(0, doc.size).set_block_format(TextBlockFormat.new(indent: 2))
    doc.blocks.all? { |b| b.block_format.indent == 2 }.should be_true
    doc.blocks.first.block_format.table_format.should be_nil
    doc.blocks.count(&.block_format.table_format).should eq(6)
    doc.undo.should be_true
    doc.to_markdown.should eq(before)
    doc.blocks.all? { |b| b.block_format.indent == 0 }.should be_true
  end
end
