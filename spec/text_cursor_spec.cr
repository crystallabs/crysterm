require "./spec_helper"

include Crysterm

private def doc_and_cursor(text = "", pos = 0)
  doc = Crysterm::TextDocument.new(text)
  {doc, Crysterm::TextCursor.new(doc, pos)}
end

describe Crysterm::TextCursor do
  describe "movement" do
    it "moves by characters across block separators" do
      _, c = doc_and_cursor("ab\ncd")
      c.move_position(:right, n: 3).should be_true
      c.position.should eq 3
      c.block_number.should eq 1
    end

    it "reports failure at document edges but moves as far as it can" do
      doc, c = doc_and_cursor("ab")
      c.move_position(:right, n: 5).should be_false
      c.position.should eq 2
      c.move_position(:left, n: 1).should be_true
      c.move_position(:start).should be_true
      c.move_position(:start).should be_false
      c.move_position(:end).should be_true
      c.position.should eq doc.size
    end

    it "moves to block boundaries" do
      _, c = doc_and_cursor("hello\nworld", 8)
      c.move_position(:start_of_block)
      c.position.should eq 6
      c.at_block_start?.should be_true
      c.move_position(:end_of_block)
      c.position.should eq 11
      c.at_block_end?.should be_true
    end

    it "moves between blocks clamping the column" do
      _, c = doc_and_cursor("abcdef\nxy", 5)
      c.move_position(:down).should be_true
      c.block_number.should eq 1
      c.position_in_block.should eq 2 # clamped to "xy"
      c.move_position(:up).should be_true
      c.block_number.should eq 0
      c.position_in_block.should eq 2 # column carried back, not restored
      c.move_position(:up).should be_false
    end

    it "moves by words, crossing separators" do
      _, c = doc_and_cursor("foo bar\nbaz qux")
      c.move_position(:word_right)
      c.position.should eq 4 # start of "bar"
      c.move_position(:word_right)
      c.position.should eq 8 # start of "baz", past the separator
      c.move_position(:word_left)
      c.position.should eq 4
      c.move_position(:word_left)
      c.position.should eq 0
      c.move_position(:word_left).should be_false
    end
  end

  describe "selection" do
    it "keeps the anchor with KeepAnchor" do
      _, c = doc_and_cursor("hello world")
      c.set_position(6)
      c.set_position(11, :keep_anchor)
      c.selection?.should be_true
      c.selection_start.should eq 6
      c.selected_text.should eq "world"
    end

    it "selects across blocks with newline separators" do
      _, c = doc_and_cursor("ab\ncd")
      c.select_span :document
      c.selected_text.should eq "ab\ncd"
    end

    it "selects the word under the cursor" do
      _, c = doc_and_cursor("foo bar baz", 5) # inside "bar"
      c.select_span :word_under_cursor
      c.selected_text.should eq "bar"
    end

    it "selects the block under the cursor" do
      _, c = doc_and_cursor("one\ntwo\nthree", 5)
      c.select_span :block_under_cursor
      c.selected_text.should eq "two"
    end
  end

  describe "editing" do
    it "advances past its own insertion" do
      doc, c = doc_and_cursor("world", 0)
      c.insert_text("hello ")
      doc.to_plain_text.should eq "hello world"
      c.position.should eq 6
    end

    it "replaces the selection on insert as a single undo step" do
      doc, c = doc_and_cursor("hello cruel world")
      c.set_position(6)
      c.set_position(11, :keep_anchor)
      c.insert_text("kind!")
      doc.to_plain_text.should eq "hello kind! world"
      c.selection?.should be_false
      doc.undo
      doc.to_plain_text.should eq "hello cruel world"
    end

    it "deletes forward and backward" do
      doc, c = doc_and_cursor("abc", 1)
      c.delete_char
      doc.to_plain_text.should eq "ac"
      c.position.should eq 1
      c.delete_previous_char
      doc.to_plain_text.should eq "c"
      c.position.should eq 0
      c.delete_previous_char # at start: no-op
      doc.to_plain_text.should eq "c"
    end

    it "inserts blocks with a format" do
      doc, c = doc_and_cursor("ab", 1)
      c.insert_block(TextBlockFormat.new(heading_level: 1))
      doc.block_count.should eq 2
      doc.to_plain_text.should eq "a\nb"
      c.block_number.should eq 1
      c.block_format.heading_level.should eq 1
      doc.blocks[0].block_format.heading_level.should eq 0
    end
  end

  describe "adjustment under concurrent edits" do
    it "shifts for edits made through other cursors" do
      doc = TextDocument.new("hello world")
      c1 = TextCursor.new(doc, 5)
      c2 = TextCursor.new(doc, 11)
      c1.insert_text("!!")
      c2.position.should eq 13
      doc.remove(0, 2)
      c1.position.should eq 5
      c2.position.should eq 11
    end

    it "does not move cursors before an insertion" do
      doc = TextDocument.new("hello")
      c = TextCursor.new(doc, 2)
      doc.insert_text(4, "x")
      c.position.should eq 2
    end

    it "collapses cursors inside a removed range to its start" do
      doc = TextDocument.new("hello world")
      c = TextCursor.new(doc, 8)
      sel = TextCursor.new(doc, 4)
      sel.set_position(10, :keep_anchor)
      doc.remove(6, 5)
      c.position.should eq 6
      sel.anchor.should eq 4
      sel.position.should eq 6
    end

    it "survives undo/redo cycles" do
      doc = TextDocument.new("abc")
      c = TextCursor.new(doc, 3)
      doc.insert_text(0, "xy")
      c.position.should eq 5
      doc.undo
      c.position.should eq 3
      doc.redo
      c.position.should eq 5
    end
  end

  describe "formats" do
    it "applies char formats to the selection" do
      doc, c = doc_and_cursor("hello world")
      c.set_position(0)
      c.set_position(5, :keep_anchor)
      c.merge_char_format(TextCharFormat.new(bold: true))
      doc.char_format_at(3).bold?.should be_true
      doc.char_format_at(7).bold?.should be_false
    end

    it "without a selection sets the typing format for the next insert" do
      doc, c = doc_and_cursor("ab", 1)
      c.set_char_format(TextCharFormat.new(italic: true))
      c.char_format.italic?.should be_true
      c.insert_text("X")
      doc.char_format_at(2).italic?.should be_true
      doc.char_format_at(1).italic?.should be_false
    end

    it "clears the pending typing format on movement" do
      _, c = doc_and_cursor("ab", 1)
      c.set_char_format(TextCharFormat.new(italic: true))
      c.move_position(:left)
      c.char_format.italic?.should be_false
    end

    it "merge preserves existing properties on the selection" do
      doc, c = doc_and_cursor
      c.insert_text("abc", TextCharFormat.new(fg: 0x00aaff))
      c.select_span :document
      c.merge_char_format(TextCharFormat.new(bold: true))
      f = doc.char_format_at(2)
      f.bold?.should be_true
      f.fg.should eq 0x00aaff
    end

    it "applies block formats to all selected blocks" do
      doc, c = doc_and_cursor("one\ntwo\nthree")
      c.set_position(1)
      c.set_position(5, :keep_anchor)
      c.set_block_format(TextBlockFormat.new(indent: 2))
      doc.blocks[0].block_format.indent.should eq 2
      doc.blocks[1].block_format.indent.should eq 2
      doc.blocks[2].block_format.indent.should eq 0
    end
  end
end
