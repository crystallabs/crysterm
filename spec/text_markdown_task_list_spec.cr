require "./spec_helper"

include Crysterm

# Task items and nested lists as GFM's reference parsers (cmark-gfm and md4c)
# read them: a plain item in a task list has no box, an ordered item takes one
# too (`1. [ ] a`), and an item that opens with a nested list (`- - a`) is an
# item of its own.

private record Item, text : String, style : String, level : Int32, task : Bool, checked : Bool

private def items(doc : TextDocument) : Array(Item)
  doc.blocks.compact_map do |b|
    bf = b.block_format
    lf = bf.list_format || next
    Item.new(b.text, lf.style.to_s, lf.indent, bf.task?, bf.checked?)
  end
end

# The Markdown *src* exports to, checked to read back to the same items and to
# export to itself again.
private def round_trip(src : String) : String
  doc = TextDocument.from_markdown(src)
  md = doc.to_markdown
  again = TextDocument.from_markdown(md)
  items(again).should eq items(doc)
  again.to_markdown.should eq md
  md
end

describe "Markdown task lists" do
  it "keeps a plain item of a task list plain" do
    doc = TextDocument.from_markdown("- [ ] a\n- [x] b\n- c\n")
    items(doc).should eq [
      Item.new("a", "Checkbox", 1, true, false),
      Item.new("b", "Checkbox", 1, true, true),
      Item.new("c", "Checkbox", 1, false, false),
    ]
    round_trip("- [ ] a\n- [x] b\n- c\n").should eq "- [ ] a\n- [x] b\n- c"
    # It shows a bullet, not a box.
    lf = doc.blocks[2].block_format.list_format.not_nil!
    disc = TextListFormat.new(style: :disc)
    lf.marker(2, task: doc.blocks[2].block_format.task?).should eq disc.marker(0)
  end

  it "reads and writes ordered task items, keeping the numbering" do
    doc = TextDocument.from_markdown("3. [ ] a\n4. [x] b\n5. c\n")
    items(doc).should eq [
      Item.new("a", "Decimal", 1, true, false),
      Item.new("b", "Decimal", 1, true, true),
      Item.new("c", "Decimal", 1, false, false),
    ]
    round_trip("3. [ ] a\n4. [x] b\n5. c\n").should eq "3. [ ] a\n4. [x] b\n5. c"
    round_trip("1. [ ] T\n   ---\n").should eq "1. [ ] T\n   ---"
    # The box shows in place of the number, as for a checkbox list's item.
    bf = doc.blocks[1].block_format
    box = TextListFormat.new(style: :checkbox)
    bf.list_format.not_nil!.marker(1, checked: true, task: bf.task?).should eq box.marker(0, checked: true)
  end

  it "keeps the outer item of `- - a`" do
    round_trip("- - a\n").should eq "- - a"
    round_trip("1. - a\n").should eq "- - a"
    round_trip("- - a\n- - b\n").should eq "- - a\n- - b"
    round_trip("- - - a\n  - b\n").should eq "- - - a\n  - b"
    round_trip("- - - a\n- - - b\n").should eq "- - - a\n- - - b"
    round_trip("> - - a\n").should eq "> - - a"
    # A list switching type inside an item with text stays in that item.
    round_trip("- x\n  - a\n  1. b\n").should eq "- x\n  - a\n  1. b"
  end

  it "writes a nested task item that opens its parent on a line of its own" do
    # cmark-gfm boxes `- [ ] a` under `-`, but not in `- - [ ] a`.
    round_trip("- - [ ] a\n").should eq "-\n  - [ ] a"
    round_trip("- - [ ] a\n- - [x] b\n").should eq "-\n  - [ ] a\n-\n  - [x] b"
  end

  it "carries task state through HTML and tags" do
    src = "1. [ ] a\n2. [x] b\n3. c\n\n- [ ] d\n- e\n"
    doc = TextDocument.from_markdown(src)
    via_html = TextDocument.new
    via_html.html = doc.to_html
    items(via_html).should eq items(doc)
    via_tags = TextDocument.new
    via_tags.tags = doc.to_tags
    items(via_tags).should eq items(doc)
  end
end
