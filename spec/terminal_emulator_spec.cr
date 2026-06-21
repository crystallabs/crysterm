require "./spec_helper"

include Crysterm

# Behaviour specs for the VT100/xterm-subset `TerminalEmulator`. The emulator is
# pure (it only depends on `Attr` and the class method `Screen.attr2code`), so it
# is exercised directly with no `Screen`/PTY.

private DFL = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)

private def emu(cols = 10, rows = 4)
  Crysterm::TerminalEmulator.new(cols, rows, DFL)
end

# The visible text of row `y` (wide-glyph continuation NULs dropped, trailing
# blanks stripped).
private def row(em, y)
  em.lines[em.ydisp + y].map(&.char).join.delete('\u0000').rstrip
end

describe Crysterm::TerminalEmulator do
  describe "printing & cursor" do
    it "prints text and advances the cursor" do
      em = emu
      em.feed "hi"
      row(em, 0).should eq "hi"
      em.cursor_x.should eq 2
      em.cursor_y.should eq 0
    end

    it "handles CR and LF" do
      em = emu
      em.feed "ab\r\ncd"
      row(em, 0).should eq "ab"
      row(em, 1).should eq "cd"
      em.cursor_y.should eq 1
    end

    it "wraps at the right margin (deferred wrap)" do
      em = emu(3, 2)
      em.feed "abc" # fills row 0; cursor parked on last column
      em.cursor_y.should eq 0
      em.feed "d" # the pending wrap now moves to row 1
      row(em, 0).should eq "abc"
      row(em, 1).should eq "d"
    end

    it "positions the cursor with CUP (row;col, 1-based)" do
      em = emu
      em.feed "\e[2;3HX"
      em.lines[1][2].char.should eq 'X'
    end
  end

  describe "SGR" do
    it "applies a foreground colour via the shared attr2code path" do
      em = emu
      em.feed "\e[31mR\e[0m"
      cell = em.lines[0][0]
      Crysterm::Attr.unpack_color(Crysterm::Attr.fg(cell.attr)).should eq 0xcd0000
    end
  end

  describe "erase" do
    it "clears to end of line (EL 0)" do
      em = emu
      em.feed "abcdef\r\e[3C\e[0K" # cursor to col 3, erase to EOL
      row(em, 0).should eq "abc"
    end

    it "clears the whole screen (ED 2)" do
      em = emu
      em.feed "x\r\ny\e[2J"
      row(em, 0).should eq ""
      row(em, 1).should eq ""
    end
  end

  describe "scrollback" do
    it "pushes scrolled-off lines into history and tracks ybase" do
      em = emu(5, 2)
      em.feed "L0\r\nL1\r\nL2\r\nL3" # no trailing newline: L3 stays on the last row
      em.ybase.should eq 2
      # The two visible rows are the most recent; L0/L1 are in scrollback.
      row(em, 0).should eq "L2"
      row(em, 1).should eq "L3"
    end

    it "scroll_to / scroll move the display offset within history" do
      em = emu(5, 2)
      4.times { |i| em.feed "L#{i}\r\n" }
      em.scroll_to 0
      em.ydisp.should eq 0
      row(em, 0).should eq "L0"
      em.reset_scroll
      em.ydisp.should eq em.ybase
    end
  end

  describe "DEC special-graphics charset" do
    it "renders G0 line-drawing after ESC ( 0 and ASCII after ESC ( B" do
      em = emu
      em.feed "\e(0lqk\e(BX"
      row(em, 0).should eq "┌─┐X"
    end

    it "switches sets with SO/SI when G1 is special" do
      em = emu
      em.feed "\e)0A\x0Eq\x0FB" # A=ascii, SO->G1(q=─), SI->G0(B)
      row(em, 0).should eq "A─B"
    end
  end

  describe "alternate screen buffer" do
    it "saves and restores the main buffer across 1049" do
      em = emu
      em.feed "MAIN"
      em.alt_active?.should be_false
      em.feed "\e[?1049h"
      em.alt_active?.should be_true
      row(em, 0).should eq "" # fresh alt page
      em.feed "\e[2J\e[HALT"
      row(em, 0).should eq "ALT"
      em.feed "\e[?1049l"
      em.alt_active?.should be_false
      row(em, 0).should eq "MAIN"
    end
  end

  describe "mouse mode tracking" do
    it "tracks the requested mode and encoding" do
      em = emu
      em.mouse_enabled?.should be_false
      em.feed "\e[?1000h\e[?1006h"
      em.mouse_enabled?.should be_true
      em.mouse_tracking.should eq 1000
      em.mouse_encoding.should eq :sgr
      em.feed "\e[?1000l"
      em.mouse_enabled?.should be_false
    end
  end

  describe "wide characters" do
    it "lays a wide glyph across two cells with a continuation follower" do
      em = emu
      em.feed "中x"
      em.lines[0][0].char.should eq '中'
      em.lines[0][1].char.should eq Crysterm::TerminalEmulator::CONTINUATION
      em.lines[0][2].char.should eq 'x'
      em.cursor_x.should eq 3
    end

    it "wraps a wide glyph that would overrun the last column" do
      em = emu(3, 2)
      em.feed "ab中" # 'ab' fill cols 0..1; 中 cannot fit in col 2 -> wraps
      row(em, 1).should eq "中"
    end
  end

  describe "origin mode" do
    it "addresses rows relative to the scroll region when DECOM is set" do
      em = emu(10, 6)
      em.feed "\e[2;5r"       # scroll region rows 2..5 (1-based)
      em.feed "\e[?6h"        # origin mode on -> cursor homes to region top
      em.cursor_y.should eq 1 # 0-based row 1 (the region top)
      em.feed "\e[1;1HX"      # row 1 in origin coords == region top
      em.lines[1][0].char.should eq 'X'
    end
  end

  describe "focus & bracketed-paste tracking" do
    it "tracks DECSET 1004 and 2004" do
      em = emu
      em.focus_reporting?.should be_false
      em.bracketed_paste?.should be_false
      em.feed "\e[?1004h\e[?2004h"
      em.focus_reporting?.should be_true
      em.bracketed_paste?.should be_true
    end
  end

  describe "DSR / cursor-position report" do
    it "answers a cursor-position request to the output sink" do
      em = emu
      io = IO::Memory.new
      em.output = io
      em.feed "\e[2;4H\e[6n"
      io.to_s.should eq "\e[2;4R"
    end
  end
end
