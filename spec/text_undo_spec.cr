require "./spec_helper"

include Crysterm

# Undo/redo semantics of `TextDocument`'s built-in stack:
# Qt-style typing coalescing, edit blocks, rich (format-preserving) restore,
# and clean-state modified tracking.
describe Crysterm::TextUndoStack do
  describe "basics" do
    it "round-trips insert and remove" do
      doc = TextDocument.new("hello")
      doc.cursor(5).insert_text(" world")
      doc.cursor(0, 1).remove_selected_text
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
      doc.cursor(0).insert_text("a")
      doc.undo
      doc.redo_available?.should be_true
      doc.cursor(0).insert_text("b")
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
      doc.cursor(0).insert_text("ab", TextCharFormat.new(bold: true))
      doc.cursor(2).insert_text("cd", TextCharFormat.new(italic: true))
      c = TextCursor.new(doc, 4)
      4.times { c.delete_previous_char }
      doc.to_plain_text.should eq ""
      doc.undo # single step past the deletions
      doc.to_plain_text.should eq "abcd"
      doc.typing_format_at(1).bold?.should be_true
      doc.typing_format_at(3).italic?.should be_true
    end
  end

  describe "undo/redo boundaries" do
    it "does not coalesce typing after an undo into a pre-undo run" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      "abc".each_char { |ch| c.insert_text(ch.to_s) }
      c.set_position(0)
      c.insert_text("Z")
      doc.undo # drops "Z"
      c.set_position(3)
      c.insert_text("d") # continues where "abc" ended, but across an undo
      doc.to_plain_text.should eq "abcd"
      doc.undo
      doc.to_plain_text.should eq "abc" # only "d" comes off
      doc.undo
      doc.to_plain_text.should eq ""
    end

    it "does not coalesce typing into a command redone mid-stack" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      c.insert_text("a")
      c.insert_text("b")
      c.set_position(0)
      c.insert_text("Z")
      c.set_position(3)
      c.insert_text("Y")
      doc.to_plain_text.should eq "ZabY"
      doc.undo
      doc.undo # back to "ab"
      doc.redo # "Zab" — a redo tail ("Y") still exists
      c.set_position(1)
      c.insert_text("q") # continues where "Z" ended, but across a redo
      doc.to_plain_text.should eq "Zqab"
      doc.undo
      doc.to_plain_text.should eq "Zab" # only "q" comes off
    end

    it "does not coalesce typing after redoing to the top of the stack" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      c.insert_text("a")
      c.insert_text("b")
      doc.undo
      doc.redo # "ab" again, no redo tail left
      c.set_position(2)
      c.insert_text("c")
      doc.undo
      doc.to_plain_text.should eq "ab" # only "c" comes off
    end

    it "starts a fresh coalescing run after the boundary" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      "abc".each_char { |ch| c.insert_text(ch.to_s) }
      doc.undo
      "de".each_char { |ch| c.insert_text(ch.to_s) }
      doc.to_plain_text.should eq "de"
      doc.undo # the post-boundary run is one step
      doc.to_plain_text.should eq ""
      doc.undo_available?.should be_false
    end

    it "keeps the clean point reachable across sealed boundaries" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      c.insert_text("a")
      doc.modified = false
      doc.undo
      doc.modified?.should be_true
      doc.redo
      doc.modified?.should be_false
      c.insert_text("b") # sealed: a new step, not a merge into "a"
      doc.modified?.should be_true
      doc.undo
      doc.modified?.should be_false
    end

    it "still invalidates the clean point truncated by typing after undo" do
      doc = TextDocument.new
      c = TextCursor.new(doc)
      c.insert_text("a")
      doc.modified = false
      doc.undo
      c.insert_text("b") # drops the redo tail holding the clean point
      doc.modified?.should be_true
      doc.undo
      doc.modified?.should be_true # clean state is unreachable
    end
  end

  describe "edit blocks" do
    it "groups arbitrary edits into one step" do
      doc = TextDocument.new("0123456789")
      doc.begin_edit_block
      doc.cursor(0).insert_text("A")
      doc.cursor(5, 7).remove_selected_text
      doc.cursor(doc.size).insert_text("Z")
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
      doc.cursor(0).insert_text("a")
      doc.begin_edit_block
      doc.cursor(1).insert_text("b")
      doc.end_edit_block
      doc.cursor(2).insert_text("c")
      doc.end_edit_block
      doc.undo
      doc.to_plain_text.should eq ""
    end
  end

  describe "rich restore" do
    it "restores char formats, block formats and structure on undo" do
      doc = TextDocument.new("Hello\nWorld")
      doc.cursor(0, 5).set_char_format(TextCharFormat.new(bold: true))
      doc.cursor(6, 6).set_block_format(TextBlockFormat.new(heading_level: 2))
      doc.begin_edit_block
      doc.cursor(0, doc.size).remove_selected_text
      doc.end_edit_block
      doc.to_plain_text.should eq ""
      doc.undo
      doc.to_plain_text.should eq "Hello\nWorld"
      doc.block_count.should eq 2
      doc.typing_format_at(1).bold?.should be_true
      doc.typing_format_at(8).bold?.should be_false
      doc.blocks[1].block_format.heading_level.should eq 2
    end

    it "undoes format changes without disturbing text or cursors" do
      doc = TextDocument.new("abcdef")
      c = TextCursor.new(doc, 4)
      doc.cursor(1, 5).set_char_format(TextCharFormat.new(underline: true))
      c.position.should eq 4
      doc.undo
      doc.to_plain_text.should eq "abcdef"
      doc.typing_format_at(3).underline?.should be_false
      c.position.should eq 4
      doc.redo
      doc.typing_format_at(3).underline?.should be_true
    end

    it "restores pre-existing formats under an undone format change" do
      doc = TextDocument.new
      doc.cursor(0).insert_text("abc", TextCharFormat.new(fg: 0xff0000))
      doc.cursor(3).insert_text("def", TextCharFormat.new(fg: 0x0000ff))
      doc.cursor(0, 6).set_char_format(TextCharFormat.new(fg: 0x00ff00))
      doc.typing_format_at(1).fg.should eq 0x00ff00
      doc.undo
      doc.typing_format_at(1).fg.should eq 0xff0000
      doc.typing_format_at(5).fg.should eq 0x0000ff
    end
  end

  describe "modified tracking" do
    it "tracks the clean state through undo/redo" do
      doc = TextDocument.new("abc")
      doc.modified?.should be_false
      doc.cursor(0).insert_text("x")
      doc.modified?.should be_true
      doc.undo
      doc.modified?.should be_false
      doc.redo
      doc.modified?.should be_true
    end

    it "honors an explicit clean point" do
      doc = TextDocument.new("abc")
      doc.cursor(0).insert_text("x")
      doc.modified = false
      doc.modified?.should be_false
      doc.cursor(0).insert_text("y")
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
      doc.cursor(0).insert_text("a")
      doc.cursor(1).insert_text("b") # coalesces; no transition
      doc.undo
      undo_events.should eq [true, false]
      redo_events.should eq [true]
    end
  end
end
