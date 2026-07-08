require "./spec_helper"

include Crysterm

# `TextDocument` (src/text/, TEXTEDIT.md Phase 1) is a pure model — these
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
      doc.block_at(0).should eq({0, 0})
      doc.block_at(2).should eq({0, 2}) # end of block 0
      doc.block_at(3).should eq({1, 0}) # start of block 1, past the separator
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
      doc.insert_text(3, "lo Worl")
      doc.to_plain_text.should eq "Hello World"
    end

    it "splits blocks on newlines" do
      doc = TextDocument.new("aabb")
      doc.insert_text(2, "1\n2\n3")
      doc.to_plain_text.should eq "aa1\n2\n3bb"
      doc.block_count.should eq 3
    end

    it "carries the block format into split-off blocks" do
      doc = TextDocument.new("aabb")
      doc.apply_block_format(0, 0, TextBlockFormat.new(heading_level: 2))
      doc.insert_text(2, "\n")
      doc.blocks[1].block_format.heading_level.should eq 2
    end
  end

  describe "#remove" do
    it "removes within a block" do
      doc = TextDocument.new("Hello cruel World")
      doc.remove(5, 6)
      doc.to_plain_text.should eq "Hello World"
    end

    it "merges blocks when the range spans separators" do
      doc = TextDocument.new("Hello\nsad\nWorld")
      doc.remove(5, 5) # "\nsad\n" -> one separator's worth of joining
      doc.to_plain_text.should eq "HelloWorld"
      doc.block_count.should eq 1
    end

    it "keeps the first block's format on merge" do
      doc = TextDocument.new("one\ntwo")
      doc.apply_block_format(0, 0, TextBlockFormat.new(heading_level: 1))
      doc.apply_block_format(4, 4, TextBlockFormat.new(heading_level: 3))
      doc.remove(3, 1) # the separator
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
      doc.insert_text(1, "X", TextCharFormat.new(bold: true, fg: 0xff0000))
      doc.char_format_at(2).bold?.should be_true
      doc.char_format_at(2).fg.should eq 0xff0000
      doc.char_format_at(1).bold?.should be_false
    end

    it "merges adjacent same-appearance fragments" do
      doc = TextDocument.new
      red = TextCharFormat.new(fg: 0xff0000)
      doc.insert_text(0, "ab", red)
      doc.insert_text(2, "cd", red)
      doc.blocks[0].fragments.size.should eq 1
      doc.blocks[0].fragments[0].text.should eq "abcd"
    end

    it "inherits the format at the insertion point when none is given" do
      doc = TextDocument.new
      doc.insert_text(0, "ab", TextCharFormat.new(italic: true))
      doc.insert_text(2, "cd")
      doc.char_format_at(4).italic?.should be_true
    end

    it "replaces formats over a range" do
      doc = TextDocument.new("abcdef")
      doc.apply_char_format(2, 4, TextCharFormat.new(underline: true))
      doc.char_format_at(2).underline?.should be_false # char before pos 2
      doc.char_format_at(3).underline?.should be_true
      doc.char_format_at(4).underline?.should be_true
      doc.char_format_at(5).underline?.should be_false
    end

    it "merge keeps unspecified properties" do
      doc = TextDocument.new
      doc.insert_text(0, "abc", TextCharFormat.new(fg: 0x00ff00))
      doc.apply_char_format(0, 3, TextCharFormat.new(bold: true), merge: true)
      f = doc.char_format_at(1)
      f.bold?.should be_true
      f.fg.should eq 0x00ff00
    end

    it "merge can explicitly unset a boolean attribute" do
      doc = TextDocument.new
      doc.insert_text(0, "abc", TextCharFormat.new(bold: true, fg: 0x00ff00))
      doc.apply_char_format(0, 3, TextCharFormat.new(bold: false), merge: true)
      f = doc.char_format_at(1)
      f.bold?.should be_false
      f.fg.should eq 0x00ff00
    end
  end

  describe "block formats" do
    it "formats every block touched by the range" do
      doc = TextDocument.new("one\ntwo\nthree")
      doc.apply_block_format(2, 5, TextBlockFormat.new(heading_level: 2))
      doc.blocks[0].block_format.heading_level.should eq 2
      doc.blocks[1].block_format.heading_level.should eq 2
      doc.blocks[2].block_format.heading_level.should eq 0
    end

    it "merges block format patches" do
      doc = TextDocument.new("one")
      doc.apply_block_format(0, 0, TextBlockFormat.new(indent: 4))
      doc.apply_block_format(0, 0, TextBlockFormat.new(heading_level: 1), merge: true)
      bf = doc.blocks[0].block_format
      bf.indent.should eq 4
      bf.heading_level.should eq 1
    end
  end

  describe "change events" do
    it "emits ContentsChange with position and delta" do
      doc = TextDocument.new("abc")
      changes = [] of {Int32, Int32, Int32}
      doc.on(Event::ContentsChange) { |e| changes << {e.position, e.chars_removed, e.chars_added} }
      doc.insert_text(1, "xy")
      doc.remove(0, 2)
      changes.should eq [{1, 0, 2}, {0, 2, 0}]
    end

    it "emits BlockCountChange when paragraphs appear" do
      doc = TextDocument.new("abc")
      counts = [] of Int32
      doc.on(Event::BlockCountChange) { |e| counts << e.count }
      doc.insert_text(1, "x")   # no block change
      doc.insert_text(1, "\n")  # 2 blocks
      doc.remove(1, 1)          # back to 1
      counts.should eq [2, 1]
    end

    it "emits ModificationChange on first edit" do
      doc = TextDocument.new("abc")
      doc.modified?.should be_false
      mods = [] of Bool
      doc.on(Event::ModificationChange) { |e| mods << e.modified }
      doc.insert_text(0, "x")
      doc.insert_text(1, "y")
      mods.should eq [true]
      doc.modified?.should be_true
    end
  end

  describe "#set_plain_text" do
    it "replaces content, clears undo and rewinds cursors" do
      doc = TextDocument.new("abc")
      cursor = TextCursor.new(doc, 3)
      doc.insert_text(0, "x")
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
