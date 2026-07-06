require "./spec_helper"

include Crysterm

# Regression specs for BUGS9 (terminal-emulator / PTY area).
#
#   BUG 1  TerminalEmulator#set_mode — DECSET private mode 1048 (`CSI ? 1048 h`
#          / `CSI ? 1048 l`) was completely unhandled. Per xterm it means "save
#          cursor as in DECSC" / "restore cursor as in DECRC" (the cursor-only
#          half of 1049, without switching to the alternate buffer). Because it
#          fell through to the `else` no-op, a child that saved its cursor with
#          `CSI ? 1048 h` and later restored it with `CSI ? 1048 l` got no
#          restore at all — the cursor stayed wherever it had moved to.

private def default_attr : Int64
  Attr.pack(0_i64, -1, -1)
end

private def emulator(cols = 10, rows = 4) : TerminalEmulator
  TerminalEmulator.new cols, rows, default_attr
end

describe "TerminalEmulator DECSET 1048 save/restore cursor (BUG 1)" do
  it "restores the cursor position saved with CSI ? 1048 h on CSI ? 1048 l" do
    em = emulator 10, 4
    em.feed "\e[3;5H" # cursor to row 3, col 5 (0-based 2,4)
    em.cursor_x.should eq 4
    em.cursor_y.should eq 2

    em.feed "\e[?1048h" # save cursor (DECSC semantics)
    em.feed "\e[1;1H"   # move to home
    em.cursor_x.should eq 0
    em.cursor_y.should eq 0

    em.feed "\e[?1048l" # restore cursor
    em.cursor_x.should eq 4
    em.cursor_y.should eq 2
  end

  it "saves/restores the SGR attribute along with the position (as DECSC does)" do
    em = emulator 10, 4
    em.feed "\e[31m"    # fg red
    em.feed "\e[?1048h" # save (position + attr)
    em.feed "\e[0m"     # reset SGR
    em.feed "\e[?1048l" # restore -> fg red again
    em.feed "X"
    # The restored attribute must NOT be the plain default (a red fg was saved).
    Attr.fg(em.lines[em.ybase][0].attr).should_not eq Attr.fg(default_attr)
  end

  it "does not switch to the alternate buffer (unlike 1049)" do
    em = emulator 10, 4
    em.feed "MAIN"
    em.feed "\e[?1048h"
    em.alt_active?.should be_false
    em.feed "\e[?1048l"
    em.alt_active?.should be_false
    em.lines[em.ybase].map(&.char).join.rstrip(' ').should eq "MAIN"
  end

  it "uses the same save slot as DECSC/DECRC" do
    em = emulator 10, 4
    em.feed "\e[2;3H"   # cursor 0-based (1,2)
    em.feed "\e[?1048h" # save via 1048
    em.feed "\e[4;4H"   # move
    em.feed "\e8"       # DECRC (ESC 8) restores the same slot
    em.cursor_x.should eq 2
    em.cursor_y.should eq 1
  end
end
