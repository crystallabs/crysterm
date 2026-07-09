require "./spec_helper"

include Crysterm

# List auto-format on typing (TEXTEDIT.md Phase-4 follow-up; Qt
# `QTextEdit::autoFormatting`): a list marker + space typed at the start of
# a plain block converts it into a list item, and the standard list-editing
# keys (Enter on an empty item, Backspace at an item's start) take the
# block back out of the list.

private def te_screen(width = 40, height = 8)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height)
end

private def new_te(s, content = "")
  te = Widget::TextEdit.new parent: s, left: 0, top: 0, width: 40, height: 8, content: content
  s._render
  te
end

private def type(te, text : String)
  text.each_char { |c| te._listener Crysterm::Event::KeyPress.new(c) }
end

private def key(te, k : ::Tput::Key)
  te._listener Crysterm::Event::KeyPress.new '\0', k
end

private def row_text(s, y, len)
  String.build do |io|
    len.times { |x| io << s.lines[y][x].char }
  end
end

describe Widget::TextEdit do
  describe "auto_formatting" do
    it "is off by default (Qt AutoNone)" do
      s = te_screen
      te = new_te s
      type te, "- one"
      te.document.blocks[0].block_format.list_format.should be_nil
      te.value.should eq "- one"
    end

    it "converts '- ' at block start into a disc list item" do
      s = te_screen
      te = new_te s
      te.auto_formatting = Widget::TextEdit::AutoFormatting::BulletList
      type te, "- one"
      blk = te.document.blocks[0]
      lf = blk.block_format.list_format.not_nil!
      lf.style.disc?.should be_true
      te.value.should eq "one"
      s._render
      row_text(s, 0, 5).should eq "• one"
    end

    it "keeps the caret at the item text while typing through the conversion" do
      s = te_screen
      te = new_te s
      te.auto_formatting = Widget::TextEdit::AutoFormatting::BulletList
      type te, "* "
      te.cursor_pos.should eq 0
      type te, "x"
      te.value.should eq "x"
      te.cursor_pos.should eq 1
    end

    it "converts 'N. ' into a decimal list starting at N when enabled" do
      s = te_screen
      te = new_te s
      te.auto_formatting = Widget::TextEdit::AutoFormatting::NumberedList
      type te, "3. three"
      lf = te.document.blocks[0].block_format.list_format.not_nil!
      lf.style.decimal?.should be_true
      lf.start.should eq 3
      s._render
      row_text(s, 0, 8).should eq "3. three"
    end

    it "does not convert numbered markers when only BulletList is enabled" do
      s = te_screen
      te = new_te s
      te.auto_formatting = Widget::TextEdit::AutoFormatting::BulletList
      type te, "1. x"
      te.document.blocks[0].block_format.list_format.should be_nil
      te.value.should eq "1. x"
    end

    it "does not re-convert inside an existing list item" do
      s = te_screen
      te = new_te s
      te.auto_formatting = Widget::TextEdit::AutoFormatting::BulletList
      type te, "- - x"
      te.value.should eq "- x"
      # Still one list item, marker text kept literally.
      TextList.new(te.document, te.document.blocks[0].block_format.list_format.not_nil!).count.should eq 1
    end

    it "one undo reverts the conversion, restoring the typed marker" do
      s = te_screen
      te = new_te s
      te.auto_formatting = Widget::TextEdit::AutoFormatting::BulletList
      type te, "- "
      te.value.should eq ""
      te.undo.should be_true
      te.value.should eq "- "
      te.document.blocks[0].block_format.list_format.should be_nil
    end

    it "Enter at the end of an item continues the list" do
      s = te_screen
      te = new_te s
      te.auto_formatting = Widget::TextEdit::AutoFormatting::BulletList
      type te, "- one"
      key te, ::Tput::Key::Enter
      type te, "two"
      lf = te.document.blocks[0].block_format.list_format.not_nil!
      list = TextList.new(te.document, lf)
      list.count.should eq 2
      s._render
      row_text(s, 1, 5).should eq "• two"
    end
  end

  describe "list editing keys" do
    it "Enter on an empty item exits the list instead of adding a block" do
      s = te_screen
      te = new_te s
      te.auto_formatting = Widget::TextEdit::AutoFormatting::BulletList
      type te, "- one"
      key te, ::Tput::Key::Enter # new empty item
      key te, ::Tput::Key::Enter # exits the list
      te.document.block_count.should eq 2
      te.document.blocks[1].block_format.list_format.should be_nil
      te.document.blocks[0].block_format.list_format.should_not be_nil
      te.value.should eq "one\n"
    end

    it "Backspace at the start of an item removes its bullet, keeping the text" do
      s = te_screen
      te = new_te s
      te.auto_formatting = Widget::TextEdit::AutoFormatting::BulletList
      type te, "- one"
      te.cursor_pos = 0
      key te, ::Tput::Key::Backspace
      te.value.should eq "one"
      te.document.blocks[0].block_format.list_format.should be_nil
      te.document.block_count.should eq 1
    end

    it "Backspace at item start does not join into the previous block" do
      s = te_screen
      te = new_te s, "above"
      te.auto_formatting = Widget::TextEdit::AutoFormatting::BulletList
      te.cursor_pos = 5
      key te, ::Tput::Key::Enter
      type te, "- item"
      te.cursor_pos = 6 # start of "item" text
      key te, ::Tput::Key::Backspace
      te.value.should eq "above\nitem"
      te.document.block_count.should eq 2
    end
  end
end
