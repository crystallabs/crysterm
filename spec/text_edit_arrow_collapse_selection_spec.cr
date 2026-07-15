require "./spec_helper"

include Crysterm

# A plain (non-shift) Left/Right arrow over an active selection must collapse the
# caret to the selection's near edge — its END for Right, its START for Left —
# rather than stepping one grapheme *past* the selection. This is the universal
# GUI/editor convention (Qt's `QLineEdit`, browsers, VS Code, …). Before the fix
# `Mixin::TextEditing#_listener` always did `@cursor_pos ± width`, so Right after
# selecting "he" (caret already at index 2) skipped to index 3 — swallowing a
# character — instead of settling at the selection end (2).
private def arrow_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

private def new_lineedit(s, value : String)
  le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 40, height: 1
  le.value = value
  s.render
  le
end

private def ctl(key : Tput::Key)
  Crysterm::Event::KeyPress.new('x', key)
end

describe "Mixin::TextEditing plain arrow collapses an active selection" do
  it "Right collapses the caret to the selection's end (not one past it)" do
    s = arrow_screen
    le = new_lineedit s, "hello"
    le.cursor_pos = 0
    le._listener ctl(Tput::Key::ShiftRight)
    le._listener ctl(Tput::Key::ShiftRight) # anchor 0, caret 2, selection "he"
    le.selected_text.should eq "he"

    le._listener ctl(Tput::Key::Right)

    le.selection?.should be_false
    le.cursor_pos.should eq 2 # collapsed to the selection end, NOT 3
  end

  it "Left collapses the caret to the selection's start (not one before it)" do
    s = arrow_screen
    le = new_lineedit s, "hello"
    le.cursor_pos = 0
    le._listener ctl(Tput::Key::ShiftRight)
    le._listener ctl(Tput::Key::ShiftRight) # anchor 0, caret 2, selection "he"

    le._listener ctl(Tput::Key::Left)

    le.selection?.should be_false
    le.cursor_pos.should eq 0 # collapsed to the selection start, NOT 1
  end

  it "a plain Left/Right with no selection still steps one grapheme" do
    s = arrow_screen
    le = new_lineedit s, "hello"
    le.cursor_pos = 2

    le._listener ctl(Tput::Key::Right)
    le.cursor_pos.should eq 3

    le._listener ctl(Tput::Key::Left)
    le.cursor_pos.should eq 2
  end
end
