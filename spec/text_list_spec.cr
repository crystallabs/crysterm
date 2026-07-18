require "./spec_helper"

include Crysterm

# `TextList`/`TextBlockGroup` (TEXTEDIT.md Phase 4): list membership by
# shared `TextListFormat` instance identity, cursor list ops, marker text,
# and the quote/rule block properties. Pure model, no PTY.

private def doc_and_cursor(text = "", pos = 0)
  doc = Crysterm::TextDocument.new(text)
  {doc, Crysterm::TextCursor.new(doc, pos)}
end

describe Crysterm::TextList do
  describe "creation and membership" do
    it "creates a list over the selected blocks" do
      doc, c = doc_and_cursor("one\ntwo\nthree")
      c.set_position(0)
      c.set_position(7, :keep_anchor) # spans blocks 0 and 1
      list = c.create_list(:disc)
      list.count.should eq 2
      list.member?(doc.blocks[0]).should be_true
      list.member?(doc.blocks[1]).should be_true
      list.member?(doc.blocks[2]).should be_false
      list.item(0).should be doc.blocks[0]
      list.item_number(doc.blocks[1]).should eq 1
      list.item_number(doc.blocks[2]).should eq -1
    end

    it "keeps other block-format properties when creating a list" do
      doc, c = doc_and_cursor("head")
      doc.apply_block_format(0, 0, TextBlockFormat.new(indent: 3))
      c.create_list(:decimal)
      doc.blocks[0].block_format.indent.should eq 3
      doc.blocks[0].block_format.list_format.should_not be_nil
    end

    it "current_list returns a view over the block's list" do
      _, c = doc_and_cursor("a\nb")
      list = c.create_list(:disc)
      c.current_list.try(&.format).should be list.format
      c.set_position(2)
      c.current_list.should be_nil
    end

    it "two lists with equal-value formats stay distinct" do
      doc, c = doc_and_cursor("a\nb")
      l1 = c.create_list(:disc)
      c.set_position(2)
      l2 = c.create_list(:disc)
      l1.count.should eq 1
      l2.count.should eq 1
      l1.member?(doc.blocks[1]).should be_false
    end
  end

  describe "structural edits" do
    it "continues the list when a block is split (Enter in an item)" do
      doc, c = doc_and_cursor("item")
      list = c.create_list(:decimal)
      c.set_position(4)
      c.insert_text("\nnext")
      list.count.should eq 2
      list.item_number(doc.blocks[1]).should eq 1
    end

    it "renumbers items when an earlier one is removed" do
      doc, c = doc_and_cursor("a\nb\nc")
      c.select_span :document
      list = c.create_list(:decimal)
      list.marker_text(doc.blocks[2]).should eq "3. "
      doc.remove(0, 2) # deletes "a\n"
      list.count.should eq 2
      list.marker_text(doc.blocks[1]).should eq "2. "
    end

    it "restores membership on undo of remove" do
      doc, c = doc_and_cursor("a\nb")
      c.select_span :document
      list = c.create_list(:disc)
      list.remove(doc.blocks[0])
      list.count.should eq 1
      doc.undo
      list.count.should eq 2
    end

    it "add and remove are undoable and keep text" do
      doc, c = doc_and_cursor("x\ny")
      c.create_list(:disc)
      list = c.current_list.not_nil!
      list.add(doc.blocks[1])
      list.count.should eq 2
      list.remove(doc.blocks[1])
      list.count.should eq 1
      doc.to_plain_text.should eq "x\ny"
    end

    it "insert_list is one undo step" do
      doc, c = doc_and_cursor("para", 4)
      list = c.insert_list(:decimal)
      doc.block_count.should eq 2
      list.member?(doc.blocks[1]).should be_true
      doc.undo
      doc.block_count.should eq 1
      doc.blocks[0].block_format.list_format.should be_nil
    end

    it "format= moves every member to the new format instance" do
      doc, c = doc_and_cursor("a\nb")
      c.select_span :document
      list = c.create_list(:disc)
      list.format = TextListFormat.new(style: :decimal)
      list.count.should eq 2
      list.marker_text(doc.blocks[0]).should eq "1. "
      doc.blocks[0].block_format.list_format.try(&.style.decimal?).should be_true
    end
  end

  describe "markers" do
    it "renders bullet styles from the glyph registry" do
      TextListFormat.new(style: :disc).marker(0).should eq "• "
      TextListFormat.new(style: :circle).marker(5).should eq "○ "
      TextListFormat.new(style: :square).marker(1).should eq "■ "
      TextListFormat.new(style: :disc).marker(0, Glyphs::Tier::Ascii).should eq "* "
    end

    it "renders numbered styles with start and affixes" do
      TextListFormat.new(style: :decimal).marker(2).should eq "3. "
      TextListFormat.new(style: :decimal, start: 10).marker(0).should eq "10. "
      TextListFormat.new(style: :lower_alpha, number_suffix: ")").marker(0).should eq "a) "
      TextListFormat.new(style: :upper_alpha).marker(25).should eq "Z. "
      TextListFormat.new(style: :lower_alpha).marker(26).should eq "aa. "
      TextListFormat.new(style: :lower_roman).marker(3).should eq "iv. "
      TextListFormat.new(style: :upper_roman, start: 1990).marker(0).should eq "MCMXC. "
      TextListFormat.new(style: :decimal, number_prefix: "(", number_suffix: ")").marker(0).should eq "(1) "
    end
  end
end

describe Crysterm::TextBlockFormat do
  it "carries quote level and horizontal rule through merge" do
    f = TextBlockFormat.new(quote_level: 2)
    f.quote_level.should eq 2
    f.horizontal_rule?.should be_false
    g = f.merge(TextBlockFormat.new(horizontal_rule: true))
    g.quote_level.should eq 2
    g.horizontal_rule?.should be_true
  end

  it "merge replaces list membership only when the patch specifies one" do
    lf = TextListFormat.new
    f = TextBlockFormat.new(list_format: lf)
    f.merge(TextBlockFormat.new(indent: 1)).list_format.should be lf
    lf2 = TextListFormat.new(style: :decimal)
    f.merge(TextBlockFormat.new(list_format: lf2)).list_format.should be lf2
    f.with_list_format(nil).list_format.should be_nil
  end
end
