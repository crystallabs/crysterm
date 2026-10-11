require "./spec_helper"

include Crysterm

# `TextDocument#block_from_source_line`, `#source_line_at` and
# `#next_source_line_after`: the lookups over `TextBlock#source_line` a
# source/preview pair syncs its carets with, in both directions.

private DOC = <<-MD
  # Title

  para one

  ---

  | a | b |
  | - | - |
  | 1 | 2 |
  MD

private def md_doc(md = DOC) : TextDocument
  TextDocument.from_markdown(md)
end

# Index of the first block stamped with *line*.
private def first_block_of(doc, line) : Int32
  (0...doc.block_count).find! { |i| doc.blocks[i].source_line == line }
end

describe "TextDocument source line lookups" do
  it "finds the first block rendered from a source line" do
    doc = md_doc
    doc.block_from_source_line(1).should eq first_block_of(doc, 1)
    doc.block_from_source_line(3).should eq first_block_of(doc, 3)
  end

  it "maps a line that rendered nothing to the nearest rendered line above" do
    doc = md_doc
    doc.block_from_source_line(2).should eq first_block_of(doc, 1)
    doc.block_from_source_line(4).should eq first_block_of(doc, 3)
    # Past the end: the last rendered line.
    top = (0...doc.block_count).compact_map { |i| doc.blocks[i].source_line }.max
    doc.block_from_source_line(999).should eq first_block_of(doc, top)
  end

  it "finds the block itself, for a caller after its position" do
    doc = md_doc
    block = doc.find_block_by_source_line(3).not_nil!
    block.source_line.should eq 3
    block.position.should eq doc.block_position(first_block_of(doc, 3))
    doc.find_block_by_source_line(0).should be_nil
  end

  it "is nil above everything rendered" do
    doc = md_doc
    doc.block_from_source_line(0).should be_nil
    doc.block_from_source_line(-5).should be_nil
  end

  it "reads a stamped block's source line back" do
    doc = md_doc
    doc.source_line_at(first_block_of(doc, 1)).should eq 1
    doc.source_line_at(first_block_of(doc, 3)).should eq 3
  end

  it "gives a generated block the nearest stamped block's line above it" do
    doc = md_doc
    generated = (1...doc.block_count).find! { |i| doc.blocks[i].source_line.nil? }
    above = (0...generated).to_a.reverse.compact_map { |i| doc.blocks[i].source_line }.first
    doc.source_line_at(generated).should eq above
  end

  it "finds the source line of the next stamped block" do
    doc = md_doc
    doc.next_source_line_after(first_block_of(doc, 1)).should eq 3
    last = (0...doc.block_count).to_a.reverse.find! { |i| doc.blocks[i].source_line }
    doc.next_source_line_after(last).should be_nil
  end

  it "finds the block in a long document, every line of it" do
    md = (1..300).map { |i| "para #{i}" }.join("\n\n")
    doc = md_doc(md)
    (1..599).each do |line|
      want = (0...doc.block_count).select { |i| (l = doc.blocks[i].source_line) && l <= line }
        .max_by { |i| doc.blocks[i].source_line.not_nil! }
      doc.block_from_source_line(line).should eq want
    end
    doc.block_from_source_line(0).should be_nil
  end

  it "is nil throughout a document without stamps" do
    doc = md_doc("")
    doc.block_from_source_line(1).should be_nil
    doc.source_line_at(0).should be_nil
    doc.next_source_line_after(0).should be_nil
  end
end
