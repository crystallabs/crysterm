require "./spec_helper"

include Crysterm

# Task-list items and headings, as GFM's reference parser (cmark-gfm, which
# github.com renders with) and md4c (QTextMarkdownImporter's parser) read
# them. The `[ ]` marker must open the item's first paragraph: a paragraph a
# setext underline makes a heading keeps it, an ATX heading's text does not,
# and `##` after the box is the task's text.

private record Shape, text : String, level : Int32, list : String?, checked : Bool

private def shapes(doc : TextDocument) : Array(Shape)
  doc.blocks.map do |b|
    bf = b.block_format
    Shape.new(b.text, bf.heading_level, bf.list_format.try(&.style.to_s), bf.checked?)
  end
end

# The Markdown *src* exports to, checked to read back to the same blocks and
# to export to itself again.
private def round_trip(src : String) : String
  doc = TextDocument.from_markdown(src)
  md = doc.to_markdown
  again = TextDocument.from_markdown(md)
  shapes(again).should eq shapes(doc)
  again.to_markdown.should eq md
  md
end

describe "Markdown task items and headings" do
  it "reads `- [ ] a` over `  ---` as a task whose text is a level-2 heading" do
    shapes(TextDocument.from_markdown("- [ ] a\n  ---\n"))
      .should eq [Shape.new("a", 2, "Checkbox", false)]
    shapes(TextDocument.from_markdown("* [x] a\n  ===\n"))
      .should eq [Shape.new("a", 1, "Checkbox", true)]
  end

  it "reads a several-line setext paragraph after the box as the heading" do
    shapes(TextDocument.from_markdown("- [ ] a\n  b\n  ---\n"))
      .should eq [Shape.new("a b", 2, "Checkbox", false)]
  end

  it "reads `- [ ] ## T` as a task with the text `## T`" do
    shapes(TextDocument.from_markdown("- [ ] ## T\n"))
      .should eq [Shape.new("## T", 0, "Checkbox", false)]
  end

  it "reads `- ## [ ] a` as a heading `[ ] a` in a plain item, with no box" do
    shapes(TextDocument.from_markdown("- ## [ ] a\n"))
      .should eq [Shape.new("[ ] a", 2, "Disc", false)]
    shapes(TextDocument.from_markdown("- # [x] b\n"))
      .should eq [Shape.new("[x] b", 1, "Disc", false)]
  end

  it "takes a box only from the item's own first paragraph" do
    # The box belongs to the inner item.
    doc = TextDocument.from_markdown("- a\n  - [ ] b\n    ---\n  - c\n")
    shapes(doc).should eq [Shape.new("a", 0, "Disc", false), Shape.new("b", 2, "Checkbox", false),
                           Shape.new("c", 0, "Checkbox", false)]
  end

  it "writes a task item's heading as a setext one at the item's content column" do
    round_trip("- [ ] a\n  ---\n").should eq "- [ ] a\n  ---"
    round_trip("- [x] a\n  ===\n").should eq "- [x] a\n  ==="
    round_trip("- [x] a\n- [ ] b\n  ---\n- [x] c\n").should eq "- [x] a\n- [ ] b\n  ---\n- [x] c"
    round_trip("- a\n  - [ ] b\n    ---\n  - [ ] c\n").should eq "- a\n  - [ ] b\n    ---\n  - [ ] c"
    round_trip("> - [x] q\n>   ===\n").should eq "> - [x] q\n>   ==="
    round_trip("- [ ] a\n  ---\n\npara\n").should eq "- [ ] a\n  ---\n\npara"
  end

  it "writes the other cases back as they read" do
    round_trip("- [ ] ## T\n").should eq "- [ ] \\## T"
    round_trip("- ## [ ] a\n").should eq "- ## \\[ \\] a"
  end

  it "writes a task heading deeper than setext allows at level 2" do
    doc = TextDocument.from_markdown("- [ ] a\n  ---\n")
    TextCursor.new(doc, 0).merge_block_format(TextBlockFormat.new(heading_level: 4))
    doc.blocks[0].block_format.heading_level.should eq 4
    doc.to_markdown.should eq "- [ ] a\n  ---"
  end
end
