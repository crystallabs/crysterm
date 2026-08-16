require "./spec_helper"

include Crysterm

# `TextDocument` (src/text/) is a pure model — these
# specs need no screen/PTY. Positions are codepoint indexes over blocks
# joined by an implicit 1-position '\n' separator.
describe Crysterm::TextDocument do
  describe "structure" do
    it "starts with one empty block" do
      doc = TextDocument.new
      doc.block_count.should eq 1
      doc.size.should eq 0
      doc.to_plain_text.should eq ""
    end

    it "splits construction text into blocks" do
      doc = TextDocument.new("ab\ncd\nef")
      doc.block_count.should eq 3
      doc.size.should eq 8 # 6 chars + 2 separators
      doc.to_plain_text.should eq "ab\ncd\nef"
    end

    it "maps positions to blocks unambiguously" do
      doc = TextDocument.new("ab\ncd\nef")
      doc.block_at(0).should eq(TextDocument::BlockLocation.new(0, 0))
      doc.block_at(2).should eq(TextDocument::BlockLocation.new(0, 2)) # end of block 0
      doc.block_at(3).should eq(TextDocument::BlockLocation.new(1, 0)) # start of block 1, past the separator
      doc.block_position(1).should eq 3
      doc.block_position(2).should eq 6
    end

    it "reads separators as newline in char_at" do
      doc = TextDocument.new("ab\ncd")
      doc.char_at(1).should eq 'b'
      doc.char_at(2).should eq '\n'
      doc.char_at(3).should eq 'c'
      doc.char_at(doc.size).should be_nil
    end
  end

  describe "#insert_text" do
    it "inserts within a block" do
      doc = TextDocument.new("Held")
      doc.cursor(3).insert_text("lo Worl")
      doc.to_plain_text.should eq "Hello World"
    end

    it "splits blocks on newlines" do
      doc = TextDocument.new("aabb")
      doc.cursor(2).insert_text("1\n2\n3")
      doc.to_plain_text.should eq "aa1\n2\n3bb"
      doc.block_count.should eq 3
    end

    it "carries the block format into split-off blocks" do
      doc = TextDocument.new("aabb")
      doc.cursor(0, 0).set_block_format(TextBlockFormat.new(heading_level: 2))
      doc.cursor(2).insert_text("\n")
      doc.blocks[1].block_format.heading_level.should eq 2
    end
  end

  describe "#remove" do
    it "removes within a block" do
      doc = TextDocument.new("Hello cruel World")
      doc.cursor(5, 11).remove_selected_text
      doc.to_plain_text.should eq "Hello World"
    end

    it "merges blocks when the range spans separators" do
      doc = TextDocument.new("Hello\nsad\nWorld")
      doc.cursor(5, 10).remove_selected_text # "\nsad\n" -> one separator's worth of joining
      doc.to_plain_text.should eq "HelloWorld"
      doc.block_count.should eq 1
    end

    it "keeps the first block's format on merge" do
      doc = TextDocument.new("one\ntwo")
      doc.cursor(0, 0).set_block_format(TextBlockFormat.new(heading_level: 1))
      doc.cursor(4, 4).set_block_format(TextBlockFormat.new(heading_level: 3))
      doc.cursor(3, 4).remove_selected_text # the separator
      doc.block_count.should eq 1
      doc.blocks[0].block_format.heading_level.should eq 1
    end
  end

  describe "plain text ranges" do
    it "slices across blocks with newline separators" do
      doc = TextDocument.new("ab\ncd\nef")
      doc.plain_text(1, 7).should eq "b\ncd\ne"
      doc.plain_text(2, 3).should eq "\n"
    end
  end

  describe "character formats" do
    it "stores the format of inserted text" do
      doc = TextDocument.new("ab")
      doc.cursor(1).insert_text("X", TextCharFormat.new(bold: true, fg: 0xff0000))
      doc.typing_format_at(2).bold?.should be_true
      doc.typing_format_at(2).fg.should eq 0xff0000
      doc.typing_format_at(1).bold?.should be_false
    end

    it "merges adjacent same-appearance fragments" do
      doc = TextDocument.new
      red = TextCharFormat.new(fg: 0xff0000)
      doc.cursor(0).insert_text("ab", red)
      doc.cursor(2).insert_text("cd", red)
      doc.blocks[0].fragments.size.should eq 1
      doc.blocks[0].fragments[0].text.should eq "abcd"
    end

    it "inherits the format at the insertion point when none is given" do
      doc = TextDocument.new
      doc.cursor(0).insert_text("ab", TextCharFormat.new(italic: true))
      doc.cursor(2).insert_text("cd")
      doc.typing_format_at(4).italic?.should be_true
    end

    it "replaces formats over a range" do
      doc = TextDocument.new("abcdef")
      doc.cursor(2, 4).set_char_format(TextCharFormat.new(underline: true))
      doc.typing_format_at(2).underline?.should be_false # char before pos 2
      doc.typing_format_at(3).underline?.should be_true
      doc.typing_format_at(4).underline?.should be_true
      doc.typing_format_at(5).underline?.should be_false
    end

    it "merge keeps unspecified properties" do
      doc = TextDocument.new
      doc.cursor(0).insert_text("abc", TextCharFormat.new(fg: 0x00ff00))
      doc.cursor(0, 3).merge_char_format(TextCharFormat.new(bold: true))
      f = doc.typing_format_at(1)
      f.bold?.should be_true
      f.fg.should eq 0x00ff00
    end

    it "merge can explicitly unset a boolean attribute" do
      doc = TextDocument.new
      doc.cursor(0).insert_text("abc", TextCharFormat.new(bold: true, fg: 0x00ff00))
      doc.cursor(0, 3).merge_char_format(TextCharFormat.new(bold: false))
      f = doc.typing_format_at(1)
      f.bold?.should be_false
      f.fg.should eq 0x00ff00
    end
  end

  describe "block formats" do
    it "formats every block touched by the range" do
      doc = TextDocument.new("one\ntwo\nthree")
      doc.cursor(2, 5).set_block_format(TextBlockFormat.new(heading_level: 2))
      doc.blocks[0].block_format.heading_level.should eq 2
      doc.blocks[1].block_format.heading_level.should eq 2
      doc.blocks[2].block_format.heading_level.should eq 0
    end

    it "merges block format patches" do
      doc = TextDocument.new("one")
      doc.cursor(0, 0).set_block_format(TextBlockFormat.new(indent: 4))
      doc.cursor(0, 0).merge_block_format(TextBlockFormat.new(heading_level: 1))
      bf = doc.blocks[0].block_format
      bf.indent.should eq 4
      bf.heading_level.should eq 1
    end
  end

  describe "change events" do
    it "emits ContentsChanged with position and delta" do
      doc = TextDocument.new("abc")
      changes = [] of {Int32, Int32, Int32}
      doc.on(Event::ContentsChanged) { |e| changes << {e.position, e.chars_removed, e.chars_added} }
      doc.cursor(1).insert_text("xy")
      doc.cursor(0, 2).remove_selected_text
      changes.should eq [{1, 0, 2}, {0, 2, 0}]
    end

    it "emits BlockCountChanged when paragraphs appear" do
      doc = TextDocument.new("abc")
      counts = [] of Int32
      doc.on(Event::BlockCountChanged) { |e| counts << e.count }
      doc.cursor(1).insert_text("x")        # no block change
      doc.cursor(1).insert_text("\n")       # 2 blocks
      doc.cursor(1, 2).remove_selected_text # back to 1
      counts.should eq [2, 1]
    end

    it "emits ModificationChanged on first edit" do
      doc = TextDocument.new("abc")
      doc.modified?.should be_false
      mods = [] of Bool
      doc.on(Event::ModificationChanged) { |e| mods << e.modified }
      doc.cursor(0).insert_text("x")
      doc.cursor(1).insert_text("y")
      mods.should eq [true]
      doc.modified?.should be_true
    end
  end

  describe "#set_plain_text" do
    it "replaces content, clears undo and rewinds cursors" do
      doc = TextDocument.new("abc")
      cursor = TextCursor.new(doc, 3)
      doc.cursor(0).insert_text("x")
      doc.undo_available?.should be_true
      doc.set_plain_text("new\ntext")
      doc.to_plain_text.should eq "new\ntext"
      doc.block_count.should eq 2
      doc.undo_available?.should be_false
      doc.modified?.should be_false
      cursor.position.should eq 0
    end
  end
end
