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

    it "discards DEL (0x7f) from the data stream instead of printing it" do
      # DEL is a fill/padding control byte; VT100/xterm ignore it. It must not be
      # written into the grid nor advance the cursor (it's `>= 0x20`, so a naive
      # printable test would leak it as a spurious cell).
      em = emu
      em.feed "a\u{7f}b"
      row(em, 0).should eq "ab"
      em.cursor_x.should eq 2
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

    it "clears the deferred wrap on CNL/CPL/VPA cursor moves" do
      # After exactly filling a row the cursor is parked in a pending-wrap state;
      # an explicit cursor move (CNL 'E', CPL 'F', VPA 'd') must cancel it, like
      # CUU/CUD/CUP do — otherwise the next printed char triggers a spurious
      # extra line-feed (and, for VPA, the wrong column).
      em = emu(3, 3)
      em.feed "abc\e[EZ" # fill row 0, CNL to row 1 col 0, print Z
      em.lines[1][0].char.should eq 'Z'
      em.cursor_y.should eq 1

      em2 = emu(3, 3)
      em2.feed "abc\e[2dZ" # fill row 0, VPA to row 1 (col unchanged = 2), print Z
      em2.lines[1][2].char.should eq 'Z'
      em2.cursor_y.should eq 1
    end

    it "restarts the parser when an ESC arrives mid-sequence" do
      # The VT500 parser treats an ESC as "abort whatever is in progress and begin
      # a new escape" from any state but the string (OSC/DCS) states. A child that
      # interrupts a half-emitted CSI with a fresh one (`CSI 1 ESC [ 2;3 H X`) must
      # have the new CSI parsed — not have its leading `[` and params leak as text.
      em = emu
      em.feed "\e[1\e[2;3HX" # incomplete "CSI 1", then a full CUP to row 2 col 3
      em.lines[1][2].char.should eq 'X'
      row(em, 0).should eq "" # nothing leaked onto the first row
    end

    it "swallows the final byte of ESC #/SP/% intermediate escapes" do
      # `ESC # n` (DECALN / double-width line), `ESC SP F` (S7C1T) and
      # `ESC % G` (UTF-8 select) are 3-byte sequences whose final byte is NOT
      # text. The emulator does not implement them, but it must consume the
      # final byte rather than printing it — otherwise e.g. a program selecting
      # a double-width line with `ESC # 6` would leak a spurious '6'.
      em = emu
      em.feed "\e#6Z"   # DECDWL select + print Z
      row(em, 0).should eq "Z"

      em2 = emu
      em2.feed "\e GA"  # ESC SP G (S8C1T) + print A
      row(em2, 0).should eq "A"

      em3 = emu
      em3.feed "\e%GB"  # ESC % G (select UTF-8) + print B
      row(em3, 0).should eq "B"
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

    it "holds the scrollback position when output arrives while scrolled back" do
      em = emu(5, 2)
      4.times { |i| em.feed "L#{i}\r\n" }
      em.scroll_to 0
      em.ydisp.should eq 0
      top = row(em, 0)
      em.feed "L4\r\n" # fresh output scrolls the live screen; the view must hold
      em.ydisp.should eq 0
      row(em, 0).should eq top
      em.ybase.should be > em.ydisp # live bottom advanced past the held view
    end

    it "follows the live bottom when output arrives and not scrolled back" do
      em = emu(5, 2)
      4.times { |i| em.feed "L#{i}\r\n" }
      em.ydisp.should eq em.ybase
      em.feed "L4\r\n"
      em.ydisp.should eq em.ybase # still tracking the bottom
    end

    it "scrolls the held view with history when scrollback overflows" do
      em = emu(5, 2)
      1100.times { em.feed "x\r\n" } # fill scrollback past SCROLLBACK_LIMIT
      em.scroll_to 500
      before = em.ydisp
      em.feed "y\r\n" # overflow path shifts every row up by one
      em.ydisp.should eq before - 1
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

    it "resets the parked main scroll region when resized on the alt screen" do
      # Quitting a full-screen app (which used the alt screen) after the window
      # grew must not leave the restored main screen scrolling inside the old,
      # smaller scroll region.
      em = emu(4, 4)
      em.feed "\e[1;1HX"  # X at row 0 of the main buffer
      em.feed "\e[?1049h" # enter alt
      em.resize(4, 6)     # window grows while on the alt screen
      em.feed "\e[?1049l" # leave alt -> main buffer restored
      # With a full-screen scroll region (rows 0..5), a line-feed from row 3 just
      # advances the cursor; with a stale region (0..3) it would scroll row 0
      # (the "X") off the top.
      em.feed "\e[4;1H\n"
      em.cursor_y.should eq 4
      row(em, 0).should eq "X"
    end

    it "does not accumulate scrollback while on the alternate screen" do
      # The alt screen has no scrollback: a full-screen app that scrolls past the
      # bottom must neither grow @ybase/@lines (unbounded memory) nor expose a
      # bogus history to scrollback navigation.
      em = emu(4, 3)
      em.feed "\e[?1049h" # enter alt
      em.ybase.should eq 0
      20.times { em.feed "x\r\n" } # scroll well past the 3-row page
      em.ybase.should eq 0
      em.lines.size.should eq 3 # exactly the visible page; nothing retained
      em.feed "\e[?1049l"       # leaving restores the main buffer intact
      em.alt_active?.should be_false
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

  describe "resize" do
    it "drops rows that fall off the bottom on shrink (no stale content on a later scroll)" do
      em = emu(4, 6)
      6.times { |i| em.feed "\e[#{i + 1};1HL#{i}" } # L0..L5 on rows 0..5
      em.resize(4, 3)                               # shrink: keep top 3 rows, drop L3..L5
      row(em, 0).should eq "L0"
      row(em, 1).should eq "L1"
      row(em, 2).should eq "L2"
      # A full-screen scroll (LF at the bottom row) must bring up a freshly blank
      # line, not the orphaned L3 that fell off the bottom on the shrink.
      em.feed "\e[3;1H\n"
      row(em, 0).should eq "L1"
      row(em, 1).should eq "L2"
      row(em, 2).should eq "" # scrolled-in blank, NOT "L3"
    end
  end

  describe "insert / delete lines (IL / DL)" do
    it "inserts blank lines at the cursor, pushing the rest down" do
      em = emu(4, 4)
      4.times { |i| em.feed "\e[#{i + 1};1HL#{i}" } # L0..L3 on rows 0..3
      em.feed "\e[2;1H\e[1L"                         # cursor row 2, insert 1 line
      row(em, 0).should eq "L0"
      row(em, 1).should eq "" # freshly inserted blank
      row(em, 2).should eq "L1"
      row(em, 3).should eq "L2" # L3 pushed off the bottom
    end

    it "deletes lines at the cursor, pulling the rest up" do
      em = emu(4, 4)
      4.times { |i| em.feed "\e[#{i + 1};1HL#{i}" }
      em.feed "\e[2;1H\e[1M" # cursor row 2, delete 1 line
      row(em, 0).should eq "L0"
      row(em, 1).should eq "L2"
      row(em, 2).should eq "L3"
      row(em, 3).should eq "" # backfilled blank
    end

    it "caps an adversarial huge count at the region size (IL)" do
      # `CSI 99999 L` must not spin O(n·height) / allocate 99999 lines: the count
      # is capped to the lines from the cursor to the region bottom, beyond which
      # the result is just a fully-blanked region.
      em = emu(4, 4)
      4.times { |i| em.feed "\e[#{i + 1};1HL#{i}" }
      em.feed "\e[2;1H\e[99999L"
      em.lines.size.should eq 4 # @lines did not grow
      row(em, 0).should eq "L0"
      row(em, 1).should eq ""
      row(em, 2).should eq ""
      row(em, 3).should eq ""
    end

    it "caps an adversarial huge count at the region size (DL)" do
      em = emu(4, 4)
      4.times { |i| em.feed "\e[#{i + 1};1HL#{i}" }
      em.feed "\e[2;1H\e[99999M"
      em.lines.size.should eq 4
      row(em, 0).should eq "L0"
      row(em, 1).should eq ""
      row(em, 2).should eq ""
      row(em, 3).should eq ""
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

    it "reports the cursor row relative to the scroll region under origin mode" do
      em = emu(10, 6)
      io = IO::Memory.new
      em.output = io
      em.feed "\e[2;5r"  # scroll region rows 2..5 (1-based)
      em.feed "\e[?6h"   # DECOM on: row addressing is region-relative
      em.feed "\e[1;1H"  # home to the region top in origin coords (== absolute row 2)
      em.feed "\e[6n"
      # The reply must echo the origin-relative row (1), not the absolute row (2),
      # so it round-trips with the CUP the child just issued.
      io.to_s.should eq "\e[1;1R"
    end
  end

  describe "OSC title vs. DCS/PM/APC strings" do
    it "reports an OSC 0/2 window title" do
      em = emu
      titles = [] of String
      em.on_title = ->(t : String) { titles << t; nil }
      em.feed "\e]0;hello\a"
      em.feed "\e]2;world\e\\" # ST-terminated
      titles.should eq ["hello", "world"]
    end

    it "swallows a DCS string without mistaking it for a title" do
      em = emu
      titles = [] of String
      em.on_title = ->(t : String) { titles << t; nil }
      # A sixel-shaped DCS payload begins '0;…' — must NOT fire on_title.
      em.feed "\e[H\eP0;1;0qABC\e\\X"
      titles.should be_empty
      em.lines[0][0].char.should eq 'X' # parsing resumed after the DCS
    end
  end

  describe "oversized CSI parameters" do
    it "does not overflow on a CSI parameter larger than Int32" do
      # A child (buggy or hostile) can emit a numeric CSI parameter far beyond
      # Int32::MAX. The in-place param accumulator must not raise OverflowError
      # (which, in the reader fiber, would silently tear down the whole session);
      # an out-of-range field reads as 0 — like the old `to_i? || 0` — so the move
      # falls back to its default and the cursor stays in bounds.
      em = emu(10, 4)
      em.feed "\e[9999999999;9999999999HX" # CUP with both fields overflowing
      em.cursor_x.should be < em.cols
      em.cursor_y.should be < em.rows
      # A real, in-range CUP still positions exactly (regression guard).
      em.feed "\e[2;3HY"
      em.lines[1][2].char.should eq 'Y'
    end

    it "does not overflow on an oversized private-mode (SGR / set_mode) parameter" do
      em = emu
      # `each_csi_param` (used by set_mode) shares the accumulator; a giant mode
      # number must be swallowed, not crash, and unknown ⇒ no state change.
      em.feed "\e[?9999999999h"
      em.feed "\e[9999999999mZ" # oversized SGR param: ignored, char still prints
      em.lines[0][0].char.should eq 'Z'
    end
  end
end
