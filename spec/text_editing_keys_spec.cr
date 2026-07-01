require "./spec_helper"

include Crysterm

# Keyboard/clipboard/multi-click editing behaviors of `Mixin::TextEditing`
# (shared by `Widget::LineEdit` and `Widget::PlainTextEdit`), companion to
# `text_selection_mouse_spec.cr` (which covers mouse cursor-positioning and
# click-drag selection). Same headless harness: a `Window` over in-memory IOs,
# a synchronous `Window#_render` (NOT `#render`, which only rings the async
# render doorbell) so geometry/painted-line caches exist, then keystrokes fed
# straight through `#_listener` (as `_read_input` wires them) and mouse events
# through `Window#dispatch_mouse` (for `#click_count`).
#
# Editing keys read `Crysterm::Config.input_readline_keys` /
# `input_clipboard_keys`; the clipboard round-trips through the in-process
# mirror at `Crysterm::Application.global.clipboard.text` (see
# `Mixin::TextEditing#text_clipboard`). Any global Config mutated here is
# restored in an `ensure` so examples don't leak state.

private def sel_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24)
end

private def mouse(action, x, y, button = ::Tput::Mouse::Button::Left)
  ::Tput::Mouse::Event.new(action, button, x, y, source: :test)
end

private def press(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Down, x, y)
end

private def drag_move(s, x, y)
  s.dispatch_mouse mouse(::Tput::Mouse::Action::Move, x, y, ::Tput::Mouse::Button::Left)
end

# A keystroke as it really arrives: `char` set for printables, `key` set for
# control sequences (matching how the input layer builds `Event::KeyPress`).
private def key(char : Char, k : ::Tput::Key? = nil)
  Crysterm::Event::KeyPress.new char, k
end

# A named control key (no meaningful char).
private def ctl(k : ::Tput::Key)
  Crysterm::Event::KeyPress.new '\0', k
end

private def new_lineedit(s, content = "hello world")
  le = Widget::LineEdit.new parent: s, left: 0, top: 0, width: 40, height: 1, content: content
  s._render
  le
end

private def new_pte(s, content = "hello world")
  pte = Widget::PlainTextEdit.new parent: s, left: 0, top: 0, width: 40, height: 5
  pte.value = content
  s._render
  pte
end

describe "Mixin::TextEditing keyboard / clipboard / multi-click editing" do
  describe "edit replaces or deletes a selection" do
    it "LineEdit: typing a character over a selection replaces the selected range" do
      s = sel_screen
      le = new_lineedit s
      # Select "hello" (indices 0...5) via a press+drag.
      press s, 0, 0
      drag_move s, 5, 0
      le.selected_text.should eq "hello"

      le._listener key('X')

      le.value.should eq "X world"
      le.cursor_pos.should eq 1
      le.has_selection?.should be_false
    end

    it "PlainTextEdit: typing a character over a selection replaces the selected range" do
      s = sel_screen
      pte = new_pte s
      press s, 0, 0
      drag_move s, 5, 0
      pte.selected_text.should eq "hello"

      pte._listener key('Z')

      pte.value.should eq "Z world"
      pte.cursor_pos.should eq 1
      pte.has_selection?.should be_false
    end

    it "LineEdit: Backspace with a selection deletes the whole selection, cursor at its start" do
      s = sel_screen
      le = new_lineedit s
      press s, 6, 0 # cursor + anchor at 6 (start of "world")
      drag_move s, 11, 0
      le.selected_text.should eq "world"

      le._listener ctl(Tput::Key::Backspace)

      le.value.should eq "hello "
      le.cursor_pos.should eq 6
      le.has_selection?.should be_false
    end

    it "LineEdit: Delete with a selection deletes the whole selection, cursor at its start" do
      s = sel_screen
      le = new_lineedit s
      press s, 0, 0
      drag_move s, 6, 0 # select "hello " (0...6)
      le.selected_text.should eq "hello "

      le._listener ctl(Tput::Key::Delete)

      le.value.should eq "world"
      le.cursor_pos.should eq 0
      le.has_selection?.should be_false
    end

    it "PlainTextEdit: Backspace with a selection deletes the whole selection" do
      s = sel_screen
      pte = new_pte s
      press s, 0, 0
      drag_move s, 5, 0 # select "hello"
      pte._listener ctl(Tput::Key::Backspace)
      pte.value.should eq " world"
      pte.cursor_pos.should eq 0
      pte.has_selection?.should be_false
    end

    it "Backspace with NO selection still removes one grapheme before the cursor" do
      s = sel_screen
      le = new_lineedit s, "abc"
      le.cursor_pos.should eq 3 # value= parks at end
      le.has_selection?.should be_false

      le._listener ctl(Tput::Key::Backspace)
      le.value.should eq "ab"
      le.cursor_pos.should eq 2
    end

    it "Delete with NO selection still removes one grapheme at the cursor" do
      s = sel_screen
      le = new_lineedit s, "abc"
      le.cursor_pos = 0
      le.has_selection?.should be_false

      le._listener ctl(Tput::Key::Delete)
      le.value.should eq "bc"
      le.cursor_pos.should eq 0
    end
  end

  describe "keyboard selection (Shift+movement)" do
    it "ShiftRight extends the selection one grapheme from the cursor" do
      s = sel_screen
      le = new_lineedit s, "hello"
      le.cursor_pos = 0

      le._listener ctl(Tput::Key::ShiftRight)
      le.selection_range.should eq(0...1)
      le.selected_text.should eq "h"
      le.selection_anchor.should eq 0
    end

    it "the anchor persists across multiple shift-moves (ShiftRight twice = 2 chars)" do
      s = sel_screen
      le = new_lineedit s, "hello"
      le.cursor_pos = 0

      le._listener ctl(Tput::Key::ShiftRight)
      le._listener ctl(Tput::Key::ShiftRight)
      le.selection_anchor.should eq 0
      le.cursor_pos.should eq 2
      le.selection_range.should eq(0...2)
      le.selected_text.should eq "he"
    end

    it "ShiftLeft after ShiftRight shrinks the selection back toward the anchor" do
      s = sel_screen
      le = new_lineedit s, "hello"
      le.cursor_pos = 0

      le._listener ctl(Tput::Key::ShiftRight)
      le._listener ctl(Tput::Key::ShiftRight) # anchor 0, cursor 2, "he"
      le._listener ctl(Tput::Key::ShiftLeft)  # cursor back to 1
      le.selection_anchor.should eq 0
      le.cursor_pos.should eq 1
      le.selection_range.should eq(0...1)
      le.selected_text.should eq "h"
    end

    it "ShiftLeft from the anchor reverses direction into a normalized range" do
      s = sel_screen
      le = new_lineedit s, "hello"
      le.cursor_pos = 3

      le._listener ctl(Tput::Key::ShiftLeft)
      le.selection_anchor.should eq 3
      le.cursor_pos.should eq 2
      le.selection_range.should eq(2...3) # normalized [lo, hi)
      le.selected_text.should eq "l"
    end

    it "ShiftHome selects from the cursor to the start of the line" do
      s = sel_screen
      le = new_lineedit s, "hello"
      le.cursor_pos = 3

      le._listener ctl(Tput::Key::ShiftHome)
      le.selection_anchor.should eq 3
      le.cursor_pos.should eq 0
      le.selection_range.should eq(0...3)
      le.selected_text.should eq "hel"
    end

    it "ShiftEnd selects from the cursor to the end of the line" do
      s = sel_screen
      le = new_lineedit s, "hello"
      le.cursor_pos = 2

      le._listener ctl(Tput::Key::ShiftEnd)
      le.selection_anchor.should eq 2
      le.cursor_pos.should eq 5
      le.selection_range.should eq(2...5)
      le.selected_text.should eq "llo"
    end

    it "a plain (non-shift) arrow after a shift-selection clears the selection" do
      s = sel_screen
      le = new_lineedit s, "hello"
      le.cursor_pos = 0

      le._listener ctl(Tput::Key::ShiftRight)
      le._listener ctl(Tput::Key::ShiftRight)
      le.has_selection?.should be_true

      le._listener ctl(Tput::Key::Right)
      le.has_selection?.should be_false
    end

    it "PlainTextEdit: ShiftDown extends the selection across a visual row" do
      s = sel_screen
      pte = new_pte s, "line one\nline two"
      pte.cursor_pos = 0

      pte._listener ctl(Tput::Key::ShiftDown)
      # Down moves one visual row to column 0 of "line two": index 9.
      pte.selection_anchor.should eq 0
      pte.cursor_pos.should eq 9
      pte.selection_range.should eq(0...9)
      pte.selected_text.should eq "line one\n"
    end
  end

  describe "select-all (Ctrl-A) is GUI-mode only" do
    it "selects the whole value when readline keys are OFF" do
      old = Crysterm::Config.input_readline_keys
      begin
        Crysterm::Config.input_readline_keys = false
        s = sel_screen
        le = new_lineedit s, "hello world"
        le.cursor_pos = 3

        le._listener ctl(Tput::Key::CtrlA)
        le.selection_range.should eq(0...11)
        le.selected_text.should eq "hello world"
        le.has_selection?.should be_true
      ensure
        Crysterm::Config.input_readline_keys = old
      end
    end

    it "moves to line start (no selection) when readline keys are ON (the default)" do
      Crysterm::Config.input_readline_keys.should be_true # sanity: default
      s = sel_screen
      le = new_lineedit s, "hello world"
      le.cursor_pos = 5

      le._listener ctl(Tput::Key::CtrlA)
      le.cursor_pos.should eq 0
      le.has_selection?.should be_false
    end
  end

  describe "cut / copy / paste (Config.input_clipboard_keys)" do
    it "Ctrl-C copies the selection to the clipboard, leaving value and selection intact" do
      s = sel_screen
      le = new_lineedit s, "hello world"
      press s, 6, 0
      drag_move s, 11, 0
      le.selected_text.should eq "world"

      le._listener ctl(Tput::Key::CtrlC)

      Crysterm::Application.global.clipboard.text.should eq "world"
      le.value.should eq "hello world" # unchanged
      le.has_selection?.should be_true # selection still present
    end

    it "Ctrl-X cuts: copies to the clipboard AND deletes the selection" do
      s = sel_screen
      le = new_lineedit s, "hello world"
      press s, 0, 0
      drag_move s, 6, 0 # "hello "
      le.selected_text.should eq "hello "

      le._listener ctl(Tput::Key::CtrlX)

      Crysterm::Application.global.clipboard.text.should eq "hello "
      le.value.should eq "world"
      le.cursor_pos.should eq 0
      le.has_selection?.should be_false
    end

    it "Ctrl-V pastes the clipboard text at the cursor" do
      Crysterm::Application.global.clipboard.text = "XYZ"
      s = sel_screen
      le = new_lineedit s, "ab"
      le.cursor_pos = 1 # between 'a' and 'b'

      le._listener ctl(Tput::Key::CtrlV)

      le.value.should eq "aXYZb"
      le.cursor_pos.should eq 4
    end

    it "Ctrl-V replaces an active selection with the clipboard text" do
      Crysterm::Application.global.clipboard.text = "QQ"
      s = sel_screen
      le = new_lineedit s, "hello world"
      press s, 0, 0
      drag_move s, 5, 0 # select "hello"
      le.selected_text.should eq "hello"

      le._listener ctl(Tput::Key::CtrlV)

      le.value.should eq "QQ world"
      le.cursor_pos.should eq 2
      le.has_selection?.should be_false
    end
  end

  describe "double / triple click (Window#click_count)" do
    it "two DOWN presses at the same cell count as a double-click and select the word" do
      s = sel_screen
      le = new_lineedit s, "hello world"

      press s, 8, 0 # within "world" (index 8 == 'r')
      s.click_count.should eq 1
      press s, 8, 0 # same spot, immediately after -> double
      s.click_count.should eq 2

      le.selected_text.should eq "world"
      le.selection_range.should eq(6...11)
    end

    it "three DOWN presses at the same cell count as a triple-click and select the whole line" do
      s = sel_screen
      le = new_lineedit s, "hello world"

      press s, 3, 0
      s.click_count.should eq 1
      press s, 3, 0
      s.click_count.should eq 2
      press s, 3, 0
      s.click_count.should eq 3

      le.selected_text.should eq "hello world"
      le.selection_range.should eq(0...11)
    end

    it "presses at DIFFERENT cells each reset the count to 1 (no multi-click)" do
      s = sel_screen
      le = new_lineedit s, "hello world"

      press s, 2, 0
      s.click_count.should eq 1
      press s, 8, 0 # different cell -> reset
      s.click_count.should eq 1

      # A single click leaves no selection (just cursor positioning).
      le.has_selection?.should be_false
      le.cursor_pos.should eq 8
    end

    it "PlainTextEdit: triple-click selects only the clicked logical line" do
      s = sel_screen
      pte = new_pte s, "line one\nline two"

      # Row 1, col 2 -> within "line two".
      press s, 2, 1
      press s, 2, 1
      press s, 2, 1
      s.click_count.should eq 3

      pte.selected_text.should eq "line two"
    end
  end

  describe "external value= clears an active selection (regression)" do
    it "LineEdit: assigning .value= drops the selection" do
      s = sel_screen
      le = new_lineedit s, "hello"
      press s, 1, 0
      drag_move s, 3, 0
      le.has_selection?.should be_true

      le.value = "goodbye"
      le.has_selection?.should be_false
      le.value.should eq "goodbye"
    end
  end
end
