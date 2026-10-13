require "./spec_helper"

# Neovim's Visual selection shown as the widget's: its end is one past the
# character under the cursor, which Neovim takes as a whole grapheme
# cluster (a letter with its combining marks, a flag of two regional
# indicators). The selection ended one code point in, splitting it, and
# the caret sat inside it.

describe Crysterm::Neovim::Handler do
  unless Crysterm::Neovim.available?
    pending "needs nvim in PATH"
    next
  end

  it "selects a character of several code points whole in Visual mode" do
    window = Crysterm::Window.new(
      input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
      width: 40, height: 10, default_quit_keys: false)
    w = Crysterm::Widget::PlainTextEdit.new parent: window, width: 40, height: 8
    # a, e + U+0301, x, space, the two regional indicators of a flag, y
    w.value = "aéx \u{1F1ED}\u{1F1F7}y"
    h = Crysterm::Neovim::Handler.new
    h.attach(w).should be_true
    h.input "0lv"
    w.selection_range.should eq 1...3
    w.cursor_position.should eq 3
    h.input "<Esc>0lvh"
    w.selection_range.should eq 0...3
    h.input "<Esc>$hv"
    w.selection_range.should eq 5...7
    w.cursor_position.should eq 7
    h.input "<Esc>$hhvl"
    w.selection_range.should eq 4...7
    h.input "<Esc>0v$"
    w.selection_range.should eq 0...8
  ensure
    h.try &.detach
    window.try &.destroy
  end
end
