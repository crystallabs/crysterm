require "./spec_helper"

include Crysterm

# Headings inside list items, as CommonMark reads them. A heading that is an
# item's first content is one block with both a heading level and the list
# (QTextMarkdownImporter's shape: `headingLevel` on a block of a `QTextList`);
# a heading further down an item is a continuation block, indented to the
# item and outside the list. Export writes each back where it was read.

private record Shape, text : String, level : Int32, list : String?, depth : Int32, quote : Int32, indent : Int32, rule : Bool

private def shapes(doc : TextDocument) : Array(Shape)
  doc.blocks.map do |b|
    bf = b.block_format
    lf = bf.list_format
    Shape.new(b.text, bf.heading_level, lf.try(&.style.to_s), lf.try(&.indent) || 0,
      bf.quote_level, bf.indent, bf.horizontal_rule?)
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

describe "Markdown headings inside list items" do
  describe "ATX headings" do
    it "imports `- ## Title` as a level-2 heading in a bullet list" do
      shapes(TextDocument.from_markdown("- ## Title\n"))
        .should eq [Shape.new("Title", 2, "Disc", 1, 0, 0, false)]
    end

    it "imports `1. # Title` as a level-1 heading in an ordered list" do
      shapes(TextDocument.from_markdown("1. # Title\n"))
        .should eq [Shape.new("Title", 1, "Decimal", 1, 0, 0, false)]
    end

    it "keeps the numbering of the items around a heading item" do
      doc = TextDocument.from_markdown("1. a\n2. ## B\n3. c\n")
      shapes(doc).map { |s| {s.text, s.level, s.list} }
        .should eq [{"a", 0, "Decimal"}, {"B", 2, "Decimal"}, {"c", 0, "Decimal"}]
      lists = doc.blocks.map(&.block_format.list_format)
      lists.uniq(&.object_id).size.should eq 1
      round_trip("1. a\n2. ## B\n3. c\n").should eq "1. a\n2. ## B\n3. c"
    end

    it "exports them back as item content" do
      round_trip("- ## Title\n").should eq "- ## Title"
      round_trip("1. # Title\n").should eq "1. # Title"
      round_trip("10. ### Ten\n").should eq "10. ### Ten"
    end

    it "keeps a paragraph after the heading in the same item" do
      src = "- ## Title\n\n  para\n- next\n"
      shapes(TextDocument.from_markdown(src)).should eq [
        Shape.new("Title", 2, "Disc", 1, 0, 0, false),
        Shape.new("para", 0, nil, 0, 0, 2, false),
        Shape.new("next", 0, "Disc", 1, 0, 0, false),
      ]
      round_trip(src).should eq "- ## Title\n\n  para\n- next"
    end
  end

  describe "setext headings" do
    it "imports an underline at the item's content column as a heading" do
      shapes(TextDocument.from_markdown("- Title\n  ---\n"))
        .should eq [Shape.new("Title", 2, "Disc", 1, 0, 0, false)]
      shapes(TextDocument.from_markdown("- Title\n  ===\n"))
        .should eq [Shape.new("Title", 1, "Disc", 1, 0, 0, false)]
      shapes(TextDocument.from_markdown("1. Title\n   ---\n"))
        .should eq [Shape.new("Title", 2, "Decimal", 1, 0, 0, false)]
    end

    it "exports them as ATX headings in the item" do
      round_trip("- Title\n  ---\n").should eq "- ## Title"
      round_trip("- Title\n  ===\n").should eq "- # Title"
      round_trip("1. Title\n   ---\n").should eq "1. ## Title"
    end
  end

  describe "headings further down an item" do
    it "imports them indented to the item, outside the list" do
      shapes(TextDocument.from_markdown("- a\n\n  ## Inner\n- b\n")).should eq [
        Shape.new("a", 0, "Disc", 1, 0, 0, false),
        Shape.new("Inner", 2, nil, 0, 0, 2, false),
        Shape.new("b", 0, "Disc", 1, 0, 0, false),
      ]
    end

    it "exports them at the item's content column, keeping them in the item" do
      round_trip("- a\n\n  ## Inner\n- b\n").should eq "- a\n\n  ## Inner\n- b"
      round_trip("1. a\n\n   Inner\n   ---\n").should eq "1. a\n\n   ## Inner"
    end
  end

  describe "nested lists" do
    it "imports a heading in a nested item at the nested depth" do
      doc = TextDocument.from_markdown("- a\n  - ### Sub\n- b\n")
      shapes(doc).map { |s| {s.text, s.level, s.depth} }
        .should eq [{"a", 0, 1}, {"Sub", 3, 2}, {"b", 0, 1}]
      round_trip("- a\n  - ### Sub\n- b\n").should eq "- a\n  - ### Sub\n- b"
    end

    it "imports a setext heading in a nested item" do
      doc = TextDocument.from_markdown("- a\n  - Sub\n    ---\n")
      shapes(doc).map { |s| {s.text, s.level, s.depth} }.should eq [{"a", 0, 1}, {"Sub", 2, 2}]
      round_trip("- a\n  - Sub\n    ---\n").should eq "- a\n  - ## Sub"
    end
  end

  describe "in a block quote" do
    it "imports a heading item in a quoted list" do
      shapes(TextDocument.from_markdown("> - ## Q\n> - b\n")).should eq [
        Shape.new("Q", 2, "Disc", 1, 1, 0, false),
        Shape.new("b", 0, "Disc", 1, 1, 0, false),
      ]
      round_trip("> - ## Q\n> - b\n").should eq "> - ## Q\n> - b"
    end

    it "imports a setext heading item in a quoted list" do
      shapes(TextDocument.from_markdown("> - Q\n>   ===\n"))
        .should eq [Shape.new("Q", 1, "Disc", 1, 1, 0, false)]
      round_trip("> - Q\n>   ===\n").should eq "> - # Q"
    end

    it "keeps a heading further down a quoted item inside the quote" do
      src = "> - a\n>\n>   ## H\n"
      shapes(TextDocument.from_markdown(src)).should eq [
        Shape.new("a", 0, "Disc", 1, 1, 0, false),
        Shape.new("H", 2, nil, 0, 1, 2, false),
      ]
      round_trip(src).should eq "> - a\n>\n>   ## H"
      round_trip("> - a\n>\n>   para\n").should eq "> - a\n>\n>   para"
    end
  end

  describe "what is not a heading" do
    it "reads `---` at column 0 after an item as a rule after the list" do
      shapes(TextDocument.from_markdown("- item\n---\n")).should eq [
        Shape.new("item", 0, "Disc", 1, 0, 0, false),
        Shape.new("", 0, nil, 0, 0, 0, true),
      ]
      round_trip("- item\n---\n").should eq "- item\n\n---"
    end

    it "reads an underline indented less than the content column as a rule" do
      shapes(TextDocument.from_markdown("- Title\n ---\n")).map { |s| {s.level, s.list, s.rule} }
        .should eq [{0, "Disc", false}, {0, nil, true}]
    end

    it "reads `- ---` as one thematic break, as CommonMark does" do
      shapes(TextDocument.from_markdown("- ---\n")).should eq [Shape.new("", 0, nil, 0, 0, 0, true)]
    end

    it "keeps a rule that is an item's content in the item" do
      ["- ***\n", "- * * *\n", "* ---\n"].each do |src|
        shapes(TextDocument.from_markdown(src)).should eq [Shape.new("", 0, "Disc", 1, 0, 0, true)]
        round_trip(src).should eq "- ***"
      end
      round_trip("1. ***\n2. x\n").should eq "1. ***\n2. x"
      round_trip("- a\n  - ***\n- b\n").should eq "- a\n\n  - ***\n- b"
    end

    it "keeps a rule further down an item in the item" do
      shapes(TextDocument.from_markdown("- a\n\n  ***\n")).should eq [
        Shape.new("a", 0, "Disc", 1, 0, 0, false),
        Shape.new("", 0, nil, 0, 0, 2, true),
      ]
      round_trip("- a\n\n  ***\n").should eq "- a\n\n  ***"
    end

    it "does not take a lazy continuation line's underline" do
      shapes(TextDocument.from_markdown("- foo\nbar\n===\n"))
        .should eq [Shape.new("foo bar ===", 0, "Disc", 1, 0, 0, false)]
      shapes(TextDocument.from_markdown("- foo\nbar\n---\n")).should eq [
        Shape.new("foo bar", 0, "Disc", 1, 0, 0, false),
        Shape.new("", 0, nil, 0, 0, 0, true),
      ]
      round_trip("- foo\nbar\n===\n").should eq "- foo bar ==="
    end
  end

  describe "outline" do
    it "lists headings in list items, nested items and quotes" do
      doc = TextDocument.from_markdown("# Top\n\n- ## In list\n  - ### Nested\n\n> 1. #### Quoted\n\n- a\n\n  ## Further\n")
      doc.outline.map { |e| {e.level, e.text} }.should eq [
        {1, "Top"}, {2, "In list"}, {3, "Nested"}, {4, "Quoted"}, {2, "Further"},
      ]
    end
  end

  describe "display" do
    it "draws a heading item with its marker, bold, and jumps to it by anchor" do
      s = headless_screen(40, 12)
      tb = Widget::TextBrowser.new parent: s, left: 0, top: 0, width: 30, height: 4
      tb.document = TextDocument.from_markdown("- plain\n- ## Title\n- a\n- b\n- c\n- d\n- e\n")
      s.repaint
      row = row_text(s, 1, 0...30)
      col = row.index!("Title")
      col.should be > 0
      row[0, col].strip.should_not be_empty # the item's marker
      (Attr.flags(s.cell_rows[1][col].attr) & Attr::BOLD).should_not eq 0
      plain = row_text(s, 0, 0...30).index!("plain")
      (Attr.flags(s.cell_rows[0][plain].attr) & Attr::BOLD).should eq 0

      tb.goto_anchor("title").should be_true
      tb.cursor_pos.should eq tb.document.block_position(1)
    end
  end
end
