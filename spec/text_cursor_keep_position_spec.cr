require "./spec_helper"

include Crysterm

# `TextCursor#keep_position_on_insert?` (Qt `keepPositionOnInsert`): text
# inserted exactly at the cursor's position leaves it there instead of
# carrying it past the new text. Text before it still moves it, text after
# it never does, removals act as on any cursor, and only the position is
# kept — the anchor moves as Qt's does.

private def keeping(doc : TextDocument, pos : Int32) : TextCursor
  TextCursor.new(doc, pos).tap(&.keep_position_on_insert = true)
end

describe "TextCursor#keep_position_on_insert" do
  it "is off by default: an insertion at the position carries it along" do
    doc = TextDocument.new "hello world"
    c = TextCursor.new(doc, 6)
    c.keep_position_on_insert?.should be_false
    TextCursor.new(doc, 6).insert_text "big "
    c.position.should eq 10
  end

  it "keeps the position on an insertion exactly there, through another cursor or its own" do
    doc = TextDocument.new "hello world"
    c = keeping(doc, 6)
    TextCursor.new(doc, 6).insert_text "big "
    doc.to_plain_text.should eq "hello big world"
    c.position.should eq 6
    c.anchor.should eq 10 # "big " is selected now, as in Qt
    c.position = 6
    c.insert_text "very "
    doc.to_plain_text.should eq "hello very big world"
    c.position.should eq 6
  end

  it "moves on an insertion before the position and not on one after" do
    doc = TextDocument.new "hello world"
    c = keeping(doc, 6)
    TextCursor.new(doc, 0).insert_text ">> "
    c.position.should eq 9
    TextCursor.new(doc, 10).insert_text "!"
    c.position.should eq 9
  end

  it "moves only the position's end: the anchor goes along as Qt's does" do
    doc = TextDocument.new "hello world"
    c = TextCursor.new(doc, 6, 6)
    c.keep_position_on_insert = true
    TextCursor.new(doc, 6).insert_text "big "
    c.position.should eq 6
    c.anchor.should eq 10
  end

  it "acts on removals around the position as any cursor does" do
    doc = TextDocument.new "hello big world"
    c = keeping(doc, 10)
    TextCursor.new(doc, 6, 10).remove_selected_text # the text before it
    c.position.should eq 6
    TextCursor.new(doc, 6, 8).remove_selected_text # the text after it
    c.position.should eq 6
    TextCursor.new(doc, 0, 2).remove_selected_text
    c.position.should eq 4
    TextCursor.new(doc, 3, 5).remove_selected_text # around it
    c.position.should eq 3
  end

  it "keeps the position when a replacement of the text starting at it is inserted" do
    doc = TextDocument.new "say foo now"
    c = keeping(doc, 4)
    plain = TextCursor.new(doc, 4)
    TextCursor.new(doc, 4, 7).insert_text "longer"
    doc.to_plain_text.should eq "say longer now"
    c.position.should eq 4
    plain.position.should eq 10
  end

  it "keeps the position when undo and redo replay an insertion there" do
    doc = TextDocument.new "hello world"
    TextCursor.new(doc, 6, 11).remove_selected_text # "hello "
    c = keeping(doc, 6)
    plain = TextCursor.new(doc, 6)
    doc.undo.should be_true # puts "world" back at 6
    doc.to_plain_text.should eq "hello world"
    c.position.should eq 6
    plain.position.should eq 11
    doc.redo.should be_true # takes it out again
    c.position.should eq 6
    TextCursor.new(doc, 6).insert_text "big "
    doc.undo.should be_true
    c.position.should eq 6
    doc.redo.should be_true # the insertion again, at the position
    c.position.should eq 6
    doc.to_plain_text.should eq "hello big "
  end
end
