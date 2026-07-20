require "./spec_helper"

include Crysterm

# Undo/redo on `Widget::PlainTextEdit`, which it gets for free from its
# `TextDocument` backing (`Mixin::TextEditing::DocumentBuffer`) — the same
# model `text_undo_spec.cr` exercises directly, driven here through the widget
# key handler. `C-z` undoes, `M-z` (AltZ) redoes. Same headless harness as
# `text_editing_keys_spec.cr`: a `Window` over in-memory IOs and keystrokes
# fed straight through `#_listener`.

private def undo_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 40,
    height: 6)
end

private def new_pte(s, content = "")
  pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 6
  pte.value = content unless content.empty?
  s.repaint
  pte
end

private def key(char : Char, k : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, k
end

private def type_str(pte, str : String)
  str.each_char { |c| pte._listener key(c) }
end

describe "Widget::PlainTextEdit undo/redo" do
  it "backs onto a real TextDocument" do
    s = undo_screen
    pte = new_pte s, "hi"
    pte.document.should be_a Crysterm::TextDocument
    pte.value.should eq "hi"
    pte.document.to_plain_text.should eq "hi"
  end

  it "undoes and redoes typed text" do
    s = undo_screen
    pte = new_pte s
    type_str pte, "hello"
    pte.value.should eq "hello"

    pte._listener key('\0', ::Tput::Key::CtrlZ)
    pte.value.should eq ""

    pte._listener key('\0', ::Tput::Key::AltZ)
    pte.value.should eq "hello"
  end

  it "undo places the caret at the change site" do
    s = undo_screen
    pte = new_pte s, "abc"
    # Caret to start, insert "X".
    pte.cursor_pos = 0
    pte._listener key('X')
    pte.value.should eq "Xabc"
    pte.cursor_pos.should eq 1

    pte._listener key('\0', ::Tput::Key::CtrlZ)
    pte.value.should eq "abc"
    pte.cursor_pos.should eq 0
  end

  it "coalesces consecutive typing into one undo step but breaks on deletion" do
    s = undo_screen
    pte = new_pte s
    type_str pte, "abc"
    pte._listener key('\0', ::Tput::Key::Backspace) # "ab"
    pte.value.should eq "ab"

    # First undo restores the deleted char; the typing run is its own step.
    pte._listener key('\0', ::Tput::Key::CtrlZ)
    pte.value.should eq "abc"
    pte._listener key('\0', ::Tput::Key::CtrlZ)
    pte.value.should eq ""
  end

  it "groups typing over a selection into a single undo step" do
    s = undo_screen
    pte = new_pte s, "hello world"
    # Select "hello" (0...5).
    pte.cursor_pos = 0
    pte.selection_anchor = 0
    pte.cursor_pos = 5
    pte.selection_anchor = 0
    pte.selected_text.should eq "hello"

    pte._listener key('Z')
    pte.value.should eq "Z world"

    # One undo restores the whole replaced selection.
    pte._listener key('\0', ::Tput::Key::CtrlZ)
    pte.value.should eq "hello world"
  end

  it "mirrors edits from a second view sharing the document" do
    s = undo_screen
    doc = Crysterm::TextDocument.new("shared")
    a = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 3, document: doc
    b = Widget::PlainTextEdit.new parent: s, left: 0, top: 3, width: 40, height: 3, document: doc
    s.repaint
    a.value.should eq "shared"
    b.value.should eq "shared"

    # Edit through view A; view B's display follows on render.
    a.cursor_pos = 6
    a._listener key('!')
    a.value.should eq "shared!"
    s.repaint
    b.value.should eq "shared!"
  end
end
