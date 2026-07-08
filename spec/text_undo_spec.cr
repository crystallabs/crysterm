require "./spec_helper"

include Crysterm

# Undo/redo semantics of `TextDocument`'s built-in stack (TEXTEDIT.md Phase 1):
# Qt-style typing coalescing, edit blocks, rich (format-preserving) restore,
# and clean-state modified tracking.
describe Crysterm::TextUndoStack do
  describe "basics" do
    it "round-trips insert and remove" do
      doc = TextDocument.new("hello")
      doc.insert_text(5, " world")
      doc.remove(0, 1)
      doc.undo.should be_true
      doc.to_plain_text.should eq "hello world"
      doc.undo.should be_true
      doc.to_plain_text.should eq "hello"
      doc.undo.should be_false
      doc.redo.should be_true
      doc.redo.should be_true
      doc.to_plain_text.should eq "ello world"
    end

    it "drops redo entries when a new edit arrives" do
      doc = TextDocument.new
      doc.insert_text(0, "a")
      doc.undo
      doc.redo_available?.should be_true
      doc.insert_text(0, "b")
      doc.redo_available?.should be_false
    end
  end

  describe "typing coalescing" do
    it "merges a contiguous typing run into one step" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      "abc".each_char { |ch| c.insert_text(ch.to_s) }
      doc.to_plain_text.should eq "abc"
      doc.undo
      doc.to_plain_text.should eq ""
      doc.undo_available?.should be_false
    end

    it "breaks the run when typing jumps elsewhere" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      c.insert_text("a")
      c.insert_text("b")
      c.set_position(0)
      c.insert_text("Z")
      doc.undo
      doc.to_plain_text.should eq "ab"
      doc.undo
      doc.to_plain_text.should eq ""
    end

    it "does not merge across newlines" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      c.insert_text("a")
      c.insert_text("\n")
      c.insert_text("b")
      doc.undo
      doc.to_plain_text.should eq "a\n"
      doc.undo
      doc.to_plain_text.should eq "a"
    end

    it "does not merge differently formatted inserts" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      c.insert_text("a")
      c.insert_text("b", TextCharFormat.new(bold: true))
      doc.undo
      doc.to_plain_text.should eq "a"
    end

    it "merges backspace runs" do
      doc = TextDocument.new("abcdef")
      c = TextCursor.new(doc, 6)
      3.times { c.delete_previous_char }
      doc.to_plain_text.should eq "abc"
      doc.undo
      doc.to_plain_text.should eq "abcdef"
      doc.undo_available?.should be_false
    end

    it "merges forward-delete runs" do
      doc = TextDocument.new("abcdef")
      c = TextCursor.new(doc, 2)
      3.times { c.delete_char }
      doc.to_plain_text.should eq "abf"
      doc.undo
      doc.to_plain_text.should eq "abcdef"
      doc.undo_available?.should be_false
    end

    it "restores formats when undoing a coalesced backspace run" do
      doc = TextDocument.new
      doc.insert_text(0, "ab", TextCharFormat.new(bold: true))
      doc.insert_text(2, "cd", TextCharFormat.new(italic: true))
      c = TextCursor.new(doc, 4)
      4.times { c.delete_previous_char }
      doc.to_plain_text.should eq ""
      doc.undo # single step past the deletions
      doc.to_plain_text.should eq "abcd"
      doc.char_format_at(1).bold?.should be_true
      doc.char_format_at(3).italic?.should be_true
    end
  end

  describe "edit blocks" do
    it "groups arbitrary edits into one step" do
      doc = TextDocument.new("0123456789")
      doc.begin_edit_block
      doc.insert_text(0, "A")
      doc.remove(5, 2)
      doc.insert_text(doc.size, "Z")
      doc.end_edit_block
      doc.undo
      doc.to_plain_text.should eq "0123456789"
      doc.undo_available?.should be_false
      doc.redo
      doc.to_plain_text.should eq "A01236789Z"
    end

    it "nests" do
      doc = TextDocument.new
      doc.begin_edit_block
      doc.insert_text(0, "a")
      doc.begin_edit_block
      doc.insert_text(1, "b")
      doc.end_edit_block
      doc.insert_text(2, "c")
      doc.end_edit_block
      doc.undo
      doc.to_plain_text.should eq ""
    end
  end

  describe "rich restore" do
    it "restores char formats, block formats and structure on undo" do
      doc = TextDocument.new("Hello\nWorld")
      doc.apply_char_format(0, 5, TextCharFormat.new(bold: true))
      doc.apply_block_format(6, 6, TextBlockFormat.new(heading_level: 2))
      doc.begin_edit_block
      doc.remove(0, doc.size)
      doc.end_edit_block
      doc.to_plain_text.should eq ""
      doc.undo
      doc.to_plain_text.should eq "Hello\nWorld"
      doc.block_count.should eq 2
      doc.char_format_at(1).bold?.should be_true
      doc.char_format_at(8).bold?.should be_false
      doc.blocks[1].block_format.heading_level.should eq 2
    end

    it "undoes format changes without disturbing text or cursors" do
      doc = TextDocument.new("abcdef")
      c = TextCursor.new(doc, 4)
      doc.apply_char_format(1, 5, TextCharFormat.new(underline: true))
      c.position.should eq 4
      doc.undo
      doc.to_plain_text.should eq "abcdef"
      doc.char_format_at(3).underline?.should be_false
      c.position.should eq 4
      doc.redo
      doc.char_format_at(3).underline?.should be_true
    end

    it "restores pre-existing formats under an undone format change" do
      doc = TextDocument.new
      doc.insert_text(0, "abc", TextCharFormat.new(fg: 0xff0000))
      doc.insert_text(3, "def", TextCharFormat.new(fg: 0x0000ff))
      doc.apply_char_format(0, 6, TextCharFormat.new(fg: 0x00ff00))
      doc.char_format_at(1).fg.should eq 0x00ff00
      doc.undo
      doc.char_format_at(1).fg.should eq 0xff0000
      doc.char_format_at(5).fg.should eq 0x0000ff
    end
  end

  describe "modified tracking" do
    it "tracks the clean state through undo/redo" do
      doc = TextDocument.new("abc")
      doc.modified?.should be_false
      doc.insert_text(0, "x")
      doc.modified?.should be_true
      doc.undo
      doc.modified?.should be_false
      doc.redo
      doc.modified?.should be_true
    end

    it "honors an explicit clean point" do
      doc = TextDocument.new("abc")
      doc.insert_text(0, "x")
      doc.modified = false
      doc.modified?.should be_false
      doc.insert_text(0, "y")
      doc.modified?.should be_true
      doc.undo
      doc.modified?.should be_false # back at the explicit clean point
      doc.undo
      doc.modified?.should be_true # before it
    end

    it "emits availability transitions" do
      doc = TextDocument.new
      undo_events = [] of Bool
      redo_events = [] of Bool
      doc.on(Event::UndoAvailable) { |e| undo_events << e.available }
      doc.on(Event::RedoAvailable) { |e| redo_events << e.available }
      doc.insert_text(0, "a")
      doc.insert_text(1, "b") # coalesces; no transition
      doc.undo
      undo_events.should eq [true, false]
      redo_events.should eq [true]
    end
  end
end
