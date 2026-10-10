require "./spec_helper"

include Crysterm

private def press(c : Char) : Event::KeyPress
  Event::KeyPress.new c
end

private def press(k : Tput::Key) : Event::KeyPress
  Event::KeyPress.new '\0', k
end

private def editor(s, text = "abcd")
  te = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 20, height: 3
  te.value = text
  s.repaint
  te
end

# `Mixin::TextEditing#overwrite_mode` (Qt's `overwriteMode`): typed characters
# replace the one under the caret instead of being inserted before it.
describe "overwrite mode" do
  it "is off by default and inserts" do
    s = headless_screen(20, 3)
    te = editor s
    te.overwrite_mode?.should be_false
    te.cursor_pos = 1
    te._listener press('X')
    te.value.should eq "aXbcd"
    te.cursor_pos.should eq 2
  end

  it "replaces the character under the caret and advances" do
    s = headless_screen(20, 3)
    te = editor s
    te.overwrite_mode = true
    te.cursor_pos = 1
    te._listener press('X')
    te._listener press('Y')
    te.value.should eq "aXYd"
    te.cursor_pos.should eq 3
  end

  it "appends at the end of the text and never consumes a line end" do
    s = headless_screen(20, 3)
    te = editor s, "ab\ncd"
    te.overwrite_mode = true
    te.cursor_pos = 2 # before the newline
    te._listener press('X')
    te.value.should eq "abX\ncd"
    te.cursor_pos = te.value.size
    te._listener press('Y')
    te.value.should eq "abX\ncdY"
  end

  it "inserts a typed line break instead of overwriting" do
    s = headless_screen(20, 3)
    te = editor s
    te.overwrite_mode = true
    te.cursor_pos = 1
    te._listener press(Tput::Key::Enter)
    te.value.should eq "a\nbcd"
  end

  it "replaces a selection as one unit, like insert mode" do
    s = headless_screen(20, 3)
    te = editor s
    te.overwrite_mode = true
    te.cursor_pos = 1
    te.selection_anchor = 3
    te._listener press('X')
    te.value.should eq "aXd"
  end

  it "replaces a wide grapheme as a whole" do
    s = headless_screen(20, 3)
    te = editor s, "a😀b"
    te.overwrite_mode = true
    te.cursor_pos = 1
    te._listener press('X')
    te.value.should eq "aXb"
  end

  it "undoes each overwritten character as one step" do
    s = headless_screen(20, 3)
    te = editor s
    te.overwrite_mode = true
    te.cursor_pos = 1
    te._listener press('X')
    te.undo
    te.value.should eq "abcd"
  end

  it "is toggled by the Insert key, emitting OverwriteModeChanged on a change" do
    s = headless_screen(20, 3)
    te = editor s
    seen = [] of Bool
    te.on(Event::OverwriteModeChanged) { |e| seen << e.overwrite }
    te._listener press(Tput::Key::Insert)
    te.overwrite_mode?.should be_true
    te._listener press(Tput::Key::Insert)
    te.overwrite_mode?.should be_false
    te.overwrite_mode = false # unchanged: no event
    seen.should eq [true, false]
    te.value.should eq "abcd"
  end

  it "does nothing in a read-only widget" do
    s = headless_screen(20, 3)
    te = editor s
    te.read_only = true
    te._listener press(Tput::Key::Insert)
    te.overwrite_mode?.should be_false
  end
end
