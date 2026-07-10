require "./spec_helper"

include Crysterm

# BUGS13 T17/T20 — `Mixin::TextEditing`: Ctrl-Y yank honoring `max_length`
# and selections, and `FlatBuffer#value=` same-string external sets still
# updating the display cursor. Headless widgets over in-memory IOs.

private def t13_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
end

private def t13_lineedit(value : String, pos : Int32)
  s = t13_screen
  le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 40, height: 1
  le.value = value
  s.render
  le.cursor_pos = pos
  le.kill_ring = Crysterm::KillRing.new # isolate from the shared default
  le
end

private def t13_press(w, key : Tput::Key)
  w._listener Crysterm::Event::KeyPress.new('x', key)
end

# A flat-buffer editor exercising `FlatBuffer#value=` directly (LineEdit
# overrides `value=`, PlainTextEdit uses `DocumentBuffer`), with a probe on
# the display-cursor update to observe that a same-string external set still
# repositions the terminal caret.
# NOTE: deliberately NOT `private` — a file-private class with these mixin
# includes trips a Crystal codegen bug (invalid GEP indices) as of 1.20.2.
class T13FlatEdit < Crysterm::Widget::Input
  getter cursor_updates = 0

  include Crysterm::Mixin::TextEditing
  include Crysterm::Mixin::TextEditing::FlatBuffer

  def _update_cursor(get = false, to_scroll_pos = false)
    @cursor_updates += 1
    super
  end
end

describe "BUGS13 T20 Ctrl-Y yank honors max_length and selections" do
  it "truncates the yanked text to the room max_length leaves" do
    le = t13_lineedit "abc", 3
    le.max_length = 5
    le.kill_ring.kill "WXYZ"
    t13_press le, Tput::Key::CtrlY
    le.value.should eq "abcWX" # was "abcWXYZ" (limit bypassed) before the fix
    le.cursor_pos.should eq 5
  end

  it "inserts nothing when the field is already full" do
    le = t13_lineedit "full!", 5
    le.max_length = 5
    le.kill_ring.kill "x"
    t13_press le, Tput::Key::CtrlY
    le.value.should eq "full!"
  end

  it "replaces a live selection instead of inserting alongside it" do
    le = t13_lineedit "hello world", 0
    le.selection_anchor = 0
    le.cursor_pos = 5
    le.kill_ring.kill "bye"
    t13_press le, Tput::Key::CtrlY
    le.value.should eq "bye world"
    le.cursor_pos.should eq 3
    le.has_selection?.should be_false
  end

  it "measures the room after the selection is freed" do
    le = t13_lineedit "abcde", 0
    le.max_length = 5
    le.selection_anchor = 0
    le.cursor_pos = 3 # "abc" selected; freeing it leaves room for 3
    le.kill_ring.kill "WXYZ"
    t13_press le, Tput::Key::CtrlY
    le.value.should eq "WXYde"
  end
end

describe "BUGS13 T17 same-string external value= still updates the display cursor" do
  it "runs _update_cursor when an external set doesn't change the string" do
    s = t13_screen
    w = T13FlatEdit.new parent: s, left: 0, top: 0, width: 20, height: 3
    w.value = "hello"
    s.render
    w.cursor_pos = 0

    before = w.cursor_updates
    w.value = "hello" # same string: caret jumps to the end, display must follow
    w.cursor_pos.should eq 5
    w.cursor_updates.should be > before # was equal (update skipped) before the fix
  end

  it "still dedups pure redisplays (nil value)" do
    s = t13_screen
    w = T13FlatEdit.new parent: s, left: 0, top: 0, width: 20, height: 3
    w.value = "hello"
    s.render
    w.cursor_pos = 2

    before = w.cursor_updates
    w.value = nil # redisplay: content unchanged, cursor kept
    w.cursor_pos.should eq 2
    w.cursor_updates.should eq before
  end
end
