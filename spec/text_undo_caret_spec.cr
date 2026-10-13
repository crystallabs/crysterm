require "./spec_helper"

include Crysterm

# Undo/redo puts the caret at the change replayed (Qt
# `QTextDocument::undo(QTextCursor*)` / `redo(QTextCursor*)`, which
# `QWidgetTextControl::undo` calls with its own cursor) — also when the step
# undone was made by another view sharing the document's undo stack, and
# after the range of a format-only step, which Qt shows the same way.

private def new_pte(s, doc : TextDocument? = nil)
  pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6, document: doc
  s.repaint
  pte
end

private def type_str(pte, str : String)
  str.each_char { |c| pte._listener kp(c) }
end

private def undo_key(pte)
  pte._listener kp('\0', ::Tput::Key::CtrlZ)
end

private def redo_key(pte)
  pte._listener kp('\0', ::Tput::Key::AltZ)
end

# "line 1" .. "line 20", one block each.
private def twenty_lines : TextDocument
  TextDocument.new((1..20).map { |i| "line #{i}" }.join('\n'))
end

private def line_start(doc : TextDocument, line : Int32) : Int32
  doc.block_position(line - 1)
end

describe "TextDocument#undo(cursor) / #redo(cursor)" do
  it "puts the cursor at the undone insert and after the redone one" do
    doc = TextDocument.new("hello world")
    doc.cursor(6).insert_text("big ")
    c = doc.cursor(0)
    doc.undo(c).should be_true
    c.position.should eq 6
    doc.redo(c).should be_true
    c.position.should eq 10
  end

  it "puts the cursor after the text a removal undo puts back" do
    doc = TextDocument.new("hello world")
    doc.cursor(0, 6).remove_selected_text
    c = doc.cursor(3)
    doc.undo(c).should be_true
    c.position.should eq 6
    c.selection?.should be_false
    doc.redo(c).should be_true
    c.position.should eq 0
  end

  it "uses the first child of an edit block on undo, the last on redo" do
    doc = TextDocument.new("hello world")
    doc.edit do
      doc.cursor(6, 11).remove_selected_text
      doc.cursor(6).insert_text("there")
    end
    c = doc.cursor(0)
    doc.undo(c).should be_true
    doc.to_plain_text.should eq "hello world"
    c.position.should eq 11
    doc.redo(c).should be_true
    c.position.should eq 11
  end

  it "puts the cursor after the range of a char format step" do
    doc = TextDocument.new("hello world")
    doc.cursor(0, 5).set_char_format(TextCharFormat.new(bold: true))
    c = doc.cursor(8)
    doc.undo(c).should be_true
    c.position.should eq 5
    c.selection?.should be_false
    doc.redo(c).should be_true
    c.position.should eq 5
  end

  it "puts the cursor at the end of the last block of a block format step" do
    doc = TextDocument.new("one\ntwo\nthree")
    doc.cursor(1, 5).set_block_format(TextBlockFormat.new(bg: 4))
    c = doc.cursor(12)
    doc.undo(c).should be_true
    c.position.should eq 7 # the end of "two"
    doc.redo(c).should be_true
    c.position.should eq 7
  end

  it "returns false and leaves the cursor with nothing to replay" do
    doc = TextDocument.new("hello")
    c = doc.cursor(2)
    doc.undo(c).should be_false
    doc.redo(c).should be_false
    c.position.should eq 2
  end

  it "rejects a cursor of another document" do
    doc = TextDocument.new("a")
    expect_raises(ArgumentError) { doc.undo(TextDocument.new("b").cursor(0)) }
  end
end

describe "PlainTextEdit undo/redo caret" do
  it "lands where it did for one view (typed text)" do
    s = headless_screen(40, 6, default_quit_keys: true)
    pte = new_pte s
    pte.value = "abc"
    pte.cursor_pos = 0
    type_str pte, "XY"
    undo_key pte
    pte.value.should eq "abc"
    pte.cursor_pos.should eq 0
    redo_key pte
    pte.value.should eq "XYabc"
    pte.cursor_pos.should eq 2
  end

  it "lands where it did for one view (backspace run)" do
    s = headless_screen(40, 6, default_quit_keys: true)
    pte = new_pte s
    pte.value = "abcdef"
    pte.cursor_pos = 4
    2.times { pte._listener kp('\0', ::Tput::Key::Backspace) }
    pte.value.should eq "abef"
    undo_key pte
    pte.value.should eq "abcdef"
    pte.cursor_pos.should eq 4
    redo_key pte
    pte.cursor_pos.should eq 2
  end

  it "goes to each step undone in turn, not the view's last edit" do
    s = headless_screen(40, 6, default_quit_keys: true)
    doc = twenty_lines
    pte = new_pte s, doc
    pte.cursor_pos = line_start(doc, 1)
    type_str pte, "x"
    pte.cursor_pos = line_start(doc, 10)
    type_str pte, "y"
    undo_key pte
    pte.cursor_pos.should eq line_start(doc, 10)
    undo_key pte
    pte.cursor_pos.should eq line_start(doc, 1)
  end

  it "takes another view's caret to the step it undoes on a shared document" do
    sa = headless_screen(40, 6, default_quit_keys: true)
    sb = headless_screen(40, 6, default_quit_keys: true)
    doc = twenty_lines
    a = new_pte sa, doc
    b = new_pte sb, doc
    b.cursor_pos = line_start(doc, 1)
    type_str b, "B"
    a.cursor_pos = line_start(doc, 16)
    type_str a, "A"
    b.cursor_pos.should eq line_start(doc, 1) + 1

    undo_key b
    doc.blocks[15].text.should eq "line 16"
    doc.blocks[0].text.should eq "Bline 1"
    b.cursor_pos.should eq line_start(doc, 16)
    doc.block_at(b.cursor_pos).index.should eq 15

    redo_key b
    doc.blocks[15].text.should eq "Aline 16"
    b.cursor_pos.should eq line_start(doc, 16) + 1
  end

  it "puts the caret after the range of a format-only undo" do
    s = headless_screen(40, 6, default_quit_keys: true)
    doc = twenty_lines
    pte = new_pte s, doc
    pte.cursor_pos = line_start(doc, 1)
    type_str pte, "x"
    doc.cursor(line_start(doc, 3), line_start(doc, 4)).set_char_format(TextCharFormat.new(bold: true))
    pte.cursor_pos = line_start(doc, 12) + 2
    undo_key pte
    doc.blocks[2].text.should eq "line 3"
    doc.blocks[0].text.should eq "xline 1"
    pte.cursor_pos.should eq line_start(doc, 4)
  end
end
