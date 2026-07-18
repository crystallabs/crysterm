require "./spec_helper"

include Crysterm

# Tests the kill ring (`Crysterm::KillRing`) and emacs/readline editing keys in
# `Mixin::TextEditing` (gated by `input.readline_keys`), exercised headlessly
# through a real `Widget::LineEdit`.

private def editor(value : String, pos : Int32)
  s = Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new)
  le = Widget::LineEdit.new parent: s, top: 0, left: 0, width: 40, height: 1
  le.value = value
  s.render # populate content/cursor geometry so motion keys can resolve
  le.cursor_pos = pos
  le.kill_ring = Crysterm::KillRing.new # isolate from the shared default
  le
end

private def press(le, key : Tput::Key)
  le._listener Crysterm::Event::KeyPress.new('x', key)
end

describe Crysterm::KillRing do
  it "stores and yanks the most recent kill" do
    kr = Crysterm::KillRing.new
    kr.yank.should be_nil
    kr.kill "abc"
    kr.yank.should eq "abc"
  end

  it "accumulates consecutive kills (append forward, prepend backward)" do
    kr = Crysterm::KillRing.new
    kr.kill "world"
    kr.kill " again"                # consecutive forward append
    kr.kill "hello ", prepend: true # consecutive backward prepend
    kr.yank.should eq "hello world again"
    kr.entries.size.should eq 1
  end

  it "starts a new entry after #interrupt" do
    kr = Crysterm::KillRing.new
    kr.kill "one"
    kr.interrupt
    kr.kill "two"
    kr.entries.should eq ["one", "two"]
    kr.yank.should eq "two"
  end

  it "caps the ring at #capacity" do
    kr = Crysterm::KillRing.new capacity: 2
    kr.kill "a"; kr.interrupt
    kr.kill "b"; kr.interrupt
    kr.kill "c"; kr.interrupt
    kr.entries.should eq ["b", "c"]
  end
end

describe "readline editing keys (Mixin::TextEditing)" do
  it "Ctrl-W kills the word before the cursor into the ring" do
    le = editor "foo bar baz", 7
    press le, Tput::Key::CtrlW
    le.value.should eq "foo  baz"
    le.cursor_pos.should eq 4
    le.kill_ring.yank.should eq "bar"
  end

  it "Alt-D kills the word after the cursor" do
    le = editor "foo bar baz", 4
    press le, Tput::Key::AltD
    le.value.should eq "foo  baz"
    le.cursor_pos.should eq 4
    le.kill_ring.yank.should eq "bar"
  end

  it "Ctrl-U kills to line start" do
    le = editor "hello world", 6
    press le, Tput::Key::CtrlU
    le.value.should eq "world"
    le.cursor_pos.should eq 0
    le.kill_ring.yank.should eq "hello "
  end

  it "Ctrl-K kills to line end" do
    le = editor "hello world", 5
    press le, Tput::Key::CtrlK
    le.value.should eq "hello"
    le.kill_ring.yank.should eq " world"
  end

  it "Ctrl-Y yanks the killed text at the cursor" do
    le = editor "foo bar baz", 7
    press le, Tput::Key::CtrlW # kill "bar" -> "foo  baz", cursor 4
    le.cursor_pos = 8          # end of "foo  baz"
    press le, Tput::Key::CtrlY
    le.value.should eq "foo  bazbar"
    le.cursor_pos.should eq 11
  end

  it "accumulates consecutive Ctrl-W kills into one ring entry" do
    le = editor "foo bar baz", 11
    press le, Tput::Key::CtrlW
    press le, Tput::Key::CtrlW
    le.value.should eq "foo "
    le.kill_ring.entries.size.should eq 1
    le.kill_ring.yank.should eq "bar baz"
  end

  it "a non-kill keystroke breaks the kill accumulation" do
    le = editor "foo bar baz", 11
    press le, Tput::Key::CtrlW     # kill "baz"
    press le, Tput::Key::Backspace # non-kill edit -> interrupt
    press le, Tput::Key::CtrlW     # new entry
    le.kill_ring.entries.size.should eq 2
  end

  it "Ctrl-A / Ctrl-E move to line start / end" do
    le = editor "hello world", 5
    press le, Tput::Key::CtrlA
    le.cursor_pos.should eq 0
    press le, Tput::Key::CtrlE
    le.cursor_pos.should eq 11
  end

  it "Ctrl-Left / Ctrl-Right move by word" do
    le = editor "foo bar baz", 11
    press le, Tput::Key::CtrlLeft
    le.cursor_pos.should eq 8
    press le, Tput::Key::CtrlLeft
    le.cursor_pos.should eq 4
    press le, Tput::Key::CtrlRight
    le.cursor_pos.should eq 7
  end

  it "Ctrl-Left / Ctrl-Right navigate by word character, stopping at '-'" do
    # "test-test2": t0 e1 s2 t3 -4 t5 e6 s7 t8 2:9, end=10. The '-' delimits
    # words, so word-char navigation lands inside the hyphenated run.
    le = editor "test-test2", 10
    press le, Tput::Key::CtrlLeft
    le.cursor_pos.should eq 5 # start of "test2"
    press le, Tput::Key::CtrlLeft
    le.cursor_pos.should eq 0 # start of "test"

    le.cursor_pos = 0
    press le, Tput::Key::CtrlRight
    le.cursor_pos.should eq 4 # one past "test" (on the '-')
    press le, Tput::Key::CtrlRight
    le.cursor_pos.should eq 10 # one past "test2" (end)
  end

  it "leaves the keys unhandled when input.readline_keys is off" do
    prev = Crysterm::Config.input_readline_keys
    begin
      Crysterm::Config.input_readline_keys = false
      le = editor "foo bar", 7
      press le, Tput::Key::CtrlW
      le.value.should eq "foo bar" # unchanged
      le.kill_ring.yank.should be_nil
    ensure
      Crysterm::Config.input_readline_keys = prev
    end
  end
end
