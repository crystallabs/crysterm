require "./spec_helper"

include Crysterm

# Second-view caret auto-adjust (TEXTEDIT.md Phase-2 known-gap follow-up):
# when several `Widget::TextEdit`s share one `TextDocument`, an edit made
# through one view (or through a bare `TextCursor` / direct document calls)
# shifts the other views' carets and selections exactly like the document
# adjusts its registered cursors — instead of merely clamping them.

private def te_screen(width = 40, height = 8)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: width,
    height: height)
end

private def new_te(s, doc, top = 0)
  te = Widget::TextEdit.new parent: s, left: 0, top: top, width: 40, height: 4, document: doc
  s._render
  te
end

private def chr(c : Char)
  Crysterm::Event::KeyPress.new c
end

describe Widget::TextEdit do
  describe "shared-document caret adjustment" do
    it "shifts the other view's caret right on an insert before it" do
      s = te_screen
      doc = TextDocument.new("hello world")
      a = new_te s, doc
      b = new_te s, doc, top: 4
      b.cursor_pos = 5
      a.cursor_pos = 0
      a._listener chr('X')
      a.cursor_pos.should eq 1
      b.cursor_pos.should eq 6
    end

    it "leaves the other view's caret put on an insert after it" do
      s = te_screen
      doc = TextDocument.new("hello")
      a = new_te s, doc
      b = new_te s, doc, top: 4
      b.cursor_pos = 2
      doc.insert_text(5, "!!")
      b.cursor_pos.should eq 2
    end

    it "collapses a caret inside a removed range to the range start" do
      s = te_screen
      doc = TextDocument.new("hello world")
      a = new_te s, doc
      b = new_te s, doc, top: 4
      b.cursor_pos = 8
      doc.remove(4, 6) # "o worl" gone
      b.cursor_pos.should eq 4
    end

    it "shifts the other view's selection, dropping it when it collapses" do
      s = te_screen
      doc = TextDocument.new("hello world")
      a = new_te s, doc
      b = new_te s, doc, top: 4
      b.selection_anchor = 6
      b.cursor_pos = 11 # "world" selected
      doc.insert_text(0, ">>")
      b.selection_anchor.should eq 8
      b.cursor_pos.should eq 13
      b.selected_text.should eq "world"
      # Removing the selected range collapses both ends onto the start —
      # the anchor is dropped rather than left dangling on the caret.
      doc.remove(8, 5)
      b.cursor_pos.should eq 8
      b.selection_anchor.should be_nil
    end

    it "does not move carets on a format-only change" do
      s = te_screen
      doc = TextDocument.new("hello world")
      a = new_te s, doc
      b = new_te s, doc, top: 4
      b.cursor_pos = 5
      doc.apply_char_format(0, 11, TextCharFormat.new(bold: true))
      b.cursor_pos.should eq 5
    end

    it "rewinds the other view's caret on a whole-content replace" do
      s = te_screen
      doc = TextDocument.new("hello world")
      a = new_te s, doc
      b = new_te s, doc, top: 4
      b.cursor_pos = 7
      doc.set_plain_text("fresh")
      b.cursor_pos.should eq 0
    end

    it "keeps the editing view's own caret semantics (no double shift)" do
      s = te_screen
      doc = TextDocument.new("abc")
      a = new_te s, doc
      a.cursor_pos = 1
      a._listener chr('X')
      doc.to_plain_text.should eq "aXbc"
      a.cursor_pos.should eq 2
      # Backspace: caret steps back over the removed grapheme, once.
      a._listener Crysterm::Event::KeyPress.new '\0', ::Tput::Key::Backspace
      doc.to_plain_text.should eq "abc"
      a.cursor_pos.should eq 1
    end

    it "adjusts the other view's caret across undo/redo replays" do
      s = te_screen
      doc = TextDocument.new("hello")
      a = new_te s, doc
      b = new_te s, doc, top: 4
      a.cursor_pos = 0
      a._listener chr('X')         # "Xhello"
      b.cursor_pos.should eq 1 + 5 # was at end (5), pushed to 6
      b.cursor_pos = 3
      a.undo.should be_true # back to "hello"
      doc.to_plain_text.should eq "hello"
      b.cursor_pos.should eq 2 # removal at 0 of 1 char shifts 3 -> 2
      a.redo.should be_true
      b.cursor_pos.should eq 3
    end

    it "renders both views correctly after a cross-view edit" do
      s = te_screen
      doc = TextDocument.new("one")
      a = new_te s, doc
      b = new_te s, doc, top: 4
      a.cursor_pos = 3
      a._listener chr('!')
      s._render
      String.build { |io| 4.times { |x| io << s.lines[0][x].char } }.should eq "one!"
      String.build { |io| 4.times { |x| io << s.lines[4][x].char } }.should eq "one!"
    end
  end
end
