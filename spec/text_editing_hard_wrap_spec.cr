require "./spec_helper"

include Crysterm

# `Mixin::TextEditing#hard_wrap_column`: static word wrap as a character is
# typed, after Kate's "Static Word Wrap". Keystrokes go straight through
# `#_listener`, as `_read_input` wires them (see `text_editing_keys_spec.cr`).

# An editor that keeps its code lines verbatim: a line starting with four
# spaces is never wrapped, as a subclass that knows its syntax would do.
private class CodeAwareEdit < Widget::PlainTextEdit
  def hard_wrap_prefix(line : String) : String?
    line.starts_with?("    ") ? nil : super
  end
end

# An editor that never starts a carried line with a `-`.
private class DashAwareEdit < Widget::PlainTextEdit
  def hard_wrap_breakable?(line : String, index : Int32) : Bool
    !line[index..].lstrip(' ').starts_with?('-')
  end
end

private def new_pte(s, content, column = 10)
  pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 5
  pte.value = content
  pte.hard_wrap_column = column
  s.repaint
  pte
end

private def type(pte, text : String)
  text.each_char { |c| pte._listener kp(c) }
end

describe "Mixin::TextEditing#hard_wrap_column" do
  it "breaks the line at the last space before the column as the character past it is typed" do
    s = headless_screen(80, 24)
    pte = new_pte s, "one two th"
    type pte, "r"
    pte.value.should eq "one two\nthr"
    pte.cursor_pos.should eq 11
    type pte, "ee four"
    pte.value.should eq "one two\nthree four"
    type pte, " "
    pte.value.should eq "one two\nthree four\n"
    pte.cursor_pos.should eq pte.value.size
    type pte, "five"
    pte.value.should eq "one two\nthree four\nfive"
  end

  it "carries the line's indentation to the new line, and the caret with the text it is in" do
    s = headless_screen(80, 24)
    pte = new_pte s, "  one tw", 8
    pte.cursor_pos = 6 # before "tw"
    type pte, "x"
    pte.value.should eq "  one\n  xtw"
    pte.cursor_pos.should eq 9 # after the x on the new line
  end

  it "breaks after a word that is longer than the column, at the first space past it" do
    s = headless_screen(80, 24)
    pte = new_pte s, "abcdefghijklmn x"
    type pte, "y"
    pte.value.should eq "abcdefghijklmn\nxy"
    pte = new_pte s, "abcdefghijklmn"
    type pte, "o"
    pte.value.should eq "abcdefghijklmno" # nowhere to break
  end

  it "undoes the keystroke and its wrap as one step" do
    s = headless_screen(80, 24)
    pte = new_pte s, "one two th"
    type pte, "r"
    pte.value.should eq "one two\nthr"
    pte.undo.should be_true
    pte.value.should eq "one two th"
    pte.redo.should be_true
    pte.value.should eq "one two\nthr"
  end

  it "leaves long lines alone without a column, on a paste, and when the prefix hook declines" do
    s = headless_screen(80, 24)
    pte = new_pte s, "one two th", nil
    type pte, "ree"
    pte.value.should eq "one two three"
    pte.hard_wrap_column = 10
    pte.insert_text " four five"
    pte.value.should eq "one two three four five"
    code = CodeAwareEdit.new parent: s, left: 0, top: 6, width: 40, height: 5
    code.value = "    code line"
    code.hard_wrap_column = 10
    s.repaint
    type code, "s"
    code.value.should eq "    code lines"
  end

  it "breaks only where #hard_wrap_breakable? allows, at an earlier space" do
    s = headless_screen(80, 24)
    pte = DashAwareEdit.new parent: s, left: 0, top: 0, width: 40, height: 5
    pte.value = "one two -thre"
    pte.hard_wrap_column = 12
    pte.cursor_pos = pte.value.size
    type pte, "e"
    pte.value.should eq "one\ntwo -three"
  end
end
