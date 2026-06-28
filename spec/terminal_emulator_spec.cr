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

    it "sticks at the last column without wrapping when autowrap (DECAWM ?7) is off" do
      # With autowrap disabled a child paints the bottom-right cell by writing
      # past the last column; the cursor must stick there and overwrite it,
      # never wrapping to (or scrolling in) the next line.
      em = emu(3, 2)
      em.feed "\e[?7l" # DECRST 7: autowrap off
      em.feed "abcd"   # 'a' 'b' 'c' fill row 0; 'd' overwrites the last column
      row(em, 0).should eq "abd"
      row(em, 1).should eq "" # nothing wrapped down
      em.cursor_y.should eq 0
      em.cursor_x.should eq 2

      # Re-enabling autowrap restores the deferred-wrap behaviour.
      em.feed "\e[?7h"
      em.feed "ef" # 'e' overwrites col 2 (pending wrap was cleared); 'f' wraps
      row(em, 0).should eq "abe"
      row(em, 1).should eq "f"
      em.cursor_y.should eq 1
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
      em.feed "\e#6Z" # DECDWL select + print Z
      row(em, 0).should eq "Z"

      em2 = emu
      em2.feed "\e GA" # ESC SP G (S8C1T) + print A
      row(em2, 0).should eq "A"

      em3 = emu
      em3.feed "\e%GB" # ESC % G (select UTF-8) + print B
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

    it "ignores a private/intermediate-prefixed CSI m (modifyOtherKeys), not as SGR" do
      # `CSI > 4 ; 2 m` is xterm's modifyOtherKeys ("set key-modifier options"),
      # which vim/neovim/tmux send at startup — it is NOT an SGR colour/style
      # change. Treating it as SGR misread its `4` as underline, so every glyph
      # printed afterwards came out wrongly underlined until the next reset.
      em = emu
      em.feed "\e[>4;2mX"
      cell = em.lines[0][0]
      cell.char.should eq 'X'
      (Crysterm::Attr.flags(cell.attr) & Crysterm::Attr::UNDERLINE).should eq 0
      # A real (unprefixed) SGR still applies, confirming the gate is specific.
      em.feed "\e[4mY"
      ycell = em.lines[0][1]
      (Crysterm::Attr.flags(ycell.attr) & Crysterm::Attr::UNDERLINE).should_not eq 0
    end

    it "does not treat a prefixed CSI u (Kitty keyboard protocol) as a cursor restore" do
      # `CSI > Pn u` / `CSI < Pn u` / `CSI = … u` push/pop/set the Kitty keyboard
      # protocol flags (neovim, fish, kakoune negotiate them at startup) — they are
      # NOT SCORC. Treating a prefixed `u` as restore-cursor yanked the cursor to
      # the last saved position (0,0 if never saved). Plain `CSI s`/`CSI u` must
      # still save/restore.
      em = emu
      em.feed "\e[s"     # SCOSC: save the home position (0,0)
      em.feed "\e[3;5HX" # move to row 3 / col 5 and print
      em.feed "\e[>1u"   # Kitty-keyboard push — must be ignored, cursor unmoved
      em.cursor_y.should eq 2
      em.cursor_x.should eq 5
      em.feed "\e[<u" # Kitty-keyboard pop — also ignored
      em.cursor_y.should eq 2
      em.cursor_x.should eq 5
      em.feed "\e[u" # plain SCORC: now the cursor returns to the saved 0,0
      em.cursor_y.should eq 0
      em.cursor_x.should eq 0
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

    it "drops only the scrollback on ED 3, leaving the visible screen intact" do
      # `CSI 3 J` is xterm's "Erase Saved Lines": it must discard the scrollback
      # history ONLY, never the visible page. A child sending a bare `CSI 3 J`
      # to trim history (without a following `CSI 2 J`) must keep what's on screen.
      em = emu(5, 2)
      em.feed "L0\r\nL1\r\nL2\r\nL3" # L0/L1 scroll into history; L2/L3 stay visible
      em.ybase.should eq 2
      em.feed "\e[3J"      # erase saved lines
      em.ybase.should eq 0 # scrollback gone
      em.ydisp.should eq 0
      em.lines.size.should eq 2 # exactly the visible page retained
      row(em, 0).should eq "L2" # visible content untouched
      row(em, 1).should eq "L3"
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

    it "restores the charset across DECSC/DECRC (ESC 7 / ESC 8)" do
      # DECSC saves the active charset along with the cursor; DECRC restores it.
      # Save and the final print happen at the *same* column so the DECRC cursor
      # restore (which also fires) doesn't overwrite an earlier glyph and confuse
      # the assertion: with G0 special saved by ESC 7, then reset to ASCII, the
      # ESC 8 must bring the line-drawing designation back — so the second 'q'
      # renders as '─' ("──"), not the literal ASCII 'q' ("─q").
      em = emu
      em.feed "\e(0" # G0 = special-graphics
      em.feed "q"    # '─' at col 0, cursor -> col 1
      em.feed "\e7"  # DECSC: save cursor (col 1) + charset (G0 special)
      em.feed "\e(B" # G0 = ASCII
      em.feed "\e8"  # DECRC: restore cursor (col 1) + G0 special again
      em.feed "q"    # '─' at col 1 (would be ASCII 'q' without charset restore)
      row(em, 0).should eq "──"
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
      em.feed "\e[2;1H\e[1L"                        # cursor row 2, insert 1 line
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

    it "moves the cursor to the left margin on IL and DL (ECMA-48 line home)" do
      # Per ECMA-48, IL/DL move the active position to the line home position
      # (column 0); xterm and modern terminals do this. The cursor must not be
      # left at its prior column.
      em = emu(10, 4)
      em.feed "\e[2;5H\e[L" # cursor row 2 / col 5 (0-based 4), then IL
      em.cursor_x.should eq 0
      em.cursor_y.should eq 1

      em.feed "\e[3;6H\e[M" # cursor row 3 / col 6, then DL
      em.cursor_x.should eq 0
      em.cursor_y.should eq 2
    end
  end

  describe "scroll up / down (SU / SD)" do
    it "scrolls the region up by SU, pushing the top line into scrollback" do
      em = emu(4, 4)
      4.times { |i| em.feed "\e[#{i + 1};1HL#{i}" } # L0..L3 on rows 0..3
      em.feed "\e[2S"                               # SU by 2
      row(em, 0).should eq "L2"
      row(em, 1).should eq "L3"
      row(em, 2).should eq ""
      row(em, 3).should eq ""
    end

    it "caps an adversarial huge SU count at the region height" do
      # `CSI 99999999 S` must not spin O(n) (nor push ~n blank lines toward the
      # scrollback limit): scrolling more than the region's height just leaves it
      # blank, so the count is capped — @lines grows by at most the region height
      # (4 lines into scrollback here), not toward SCROLLBACK_LIMIT.
      em = emu(4, 4)
      4.times { |i| em.feed "\e[#{i + 1};1HL#{i}" }
      em.feed "\e[99999999S"
      em.lines.size.should eq 8 # 4 visible + the 4 original lines in scrollback
      em.ybase.should eq 4
      (0...4).each { |y| row(em, y).should eq "" } # visible screen fully blank
    end

    it "caps an adversarial huge SD count at the region height" do
      em = emu(4, 4)
      4.times { |i| em.feed "\e[#{i + 1};1HL#{i}" }
      em.feed "\e[99999999T"    # SD: content moves down, blanks from the top
      em.lines.size.should eq 4 # SD never touches scrollback
      (0...4).each { |y| row(em, y).should eq "" }
    end
  end

  describe "cursor up/down within a scroll region" do
    it "clamps CUU/CUD to the scroll-region margins, not the screen edges" do
      # xterm's CursorUp/CursorDown stop at the scroll region's top/bottom margin
      # when the cursor starts inside the region — so a child driving a bounded
      # status area with CUU/CUD can't walk the cursor out of its region. A naive
      # clamp to the screen edges (0 / rows-1) lets it escape.
      em = emu(10, 10)
      em.feed "\e[3;7r" # scroll region rows 3..7 (1-based) == 0-based rows 2..6

      em.feed "\e[6;1H" # absolute row 6 (1-based) == 0-based row 5, inside region
      em.cursor_y.should eq 5
      em.feed "\e[10A"        # CUU far past the top: must stop at the top margin
      em.cursor_y.should eq 2 # scroll_top, NOT 0

      em.feed "\e[4;1H" # 0-based row 3, inside the region
      em.cursor_y.should eq 3
      em.feed "\e[10B"        # CUD far past the bottom: must stop at the bottom margin
      em.cursor_y.should eq 6 # scroll_bottom, NOT 9
    end

    it "does not treat a private-prefixed CSI r (XTRESTORE) as DECSTBM" do
      # `CSI ? Pm r` is XTRESTORE (restore DEC private mode values) — the
      # counterpart to the `CSI ? Pm s` XTSAVE the 's' handler already ignores.
      # xterm-aware children pair them around a mode change, e.g. `CSI ? 7 r` to
      # restore autowrap. Letting that fall through to DECSTBM misread its `7` as
      # a top margin (rows 6..bottom) and homed the cursor — corrupting an app's
      # scroll region. It must be a no-op (we don't track saved modes).
      em = emu(10, 10)
      em.feed "\e[6;4HX"      # park the cursor at 0-based row 5, col 3
      em.cursor_x.should eq 4 # after printing 'X'
      em.cursor_y.should eq 5
      em.feed "\e[?7r"        # XTRESTORE autowrap: must NOT touch the scroll region
      em.cursor_x.should eq 4 # real DECSTBM would have homed to (0,0)
      em.cursor_y.should eq 5
      # The full-screen region is intact: CUD walks all the way to the screen
      # bottom (row 9), not a bogus margin a stray DECSTBM would have installed.
      em.feed "\e[20B"
      em.cursor_y.should eq 9
    end
  end

  describe "reverse index (RI / ESC M)" do
    it "clears the deferred (last-column) wrap so the next glyph overwrites at the cursor" do
      # RI repositions the active line, so — like its mirror IND (LF) and every
      # CSI cursor move — it must cancel a pending last-column wrap. If the stale
      # `@wrap_pending` survives, the glyph printed right after RI spuriously
      # wraps to the next line instead of overwriting at the cursor's column.
      em = emu(3, 3)
      em.feed "\e[2;1H" # cursor to 0-based row 1 (middle), col 0
      em.feed "XYZ"     # fills row 1; cursor parks on the last column (wrap pending)
      em.cursor_y.should eq 1

      em.feed "\eM" # RI: move up to row 0 (no scroll); must clear wrap-pending
      em.cursor_y.should eq 0

      em.feed "Q"             # must land at the cursor's actual column on row 0
      em.cursor_y.should eq 0 # NOT pushed down to row 1 by a spurious wrap
      row(em, 0).should eq "  Q"
      row(em, 1).should eq "XYZ" # row 1 untouched (Q did not wrap onto it)
    end
  end

  describe "DECSTBM (set scroll region)" do
    it "clamps an over-large bottom margin instead of dropping the whole request" do
      # xterm clamps a DECSTBM bottom that exceeds the screen to the last row and
      # still installs the region; it does NOT reject the request. A child that
      # still uses its pre-resize row count can emit `CSI 1;<oldrows> r` before it
      # handles SIGWINCH — rejecting that left the previous (smaller) region in
      # place, so scrolling stayed confined to it. After clamping, the region is
      # the full screen and a line-feed below the old margin no longer scrolls.
      em = emu(4, 4)
      em.feed "\e[1;2r"  # first install a small region: 0-based rows 0..1
      em.feed "\e[1;1HA" # 'A' at row 0

      # Now an oversized DECSTBM (bottom 99 > 4 rows). Buggy code drops it, leaving
      # the 0..1 region; fixed code clamps to the full 0..3 region.
      em.feed "\e[1;99r"

      # Put the cursor on the *old* region's bottom margin (0-based row 1) and feed
      # a line-feed. With the stale small region that LF scrolls (row 0's 'A' moves
      # up and is lost); with the full region it just advances the cursor to row 2.
      em.feed "\e[2;1H\n"
      em.cursor_y.should eq 2  # advanced, not scrolled (full region in effect)
      row(em, 0).should eq "A" # row 0 untouched — no scroll happened
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
      em.feed "\e[2;5r" # scroll region rows 2..5 (1-based)
      em.feed "\e[?6h"  # DECOM on: row addressing is region-relative
      em.feed "\e[1;1H" # home to the region top in origin coords (== absolute row 2)
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

  describe "tab stops (HT / HTS / TBC / CHT / CBT)" do
    it "advances HT to the default 8-column stops" do
      em = emu(20, 2)
      em.feed "\tA" # HT from col 0 -> col 8
      em.lines[0][8].char.should eq 'A'
    end

    it "honours a tab stop set with HTS (ESC H)" do
      # Clear all stops, set a single custom stop at column 4, then HT must land
      # there — not on a hardcoded 8-column boundary.
      em = emu(20, 2)
      em.feed "\e[3g"      # TBC 3: clear every stop
      em.feed "\e[1;5H\eH" # cursor to col 4 (0-based), HTS sets a stop here
      em.feed "\r\tX"      # CR to col 0, HT -> the only stop (col 4)
      em.lines[0][4].char.should eq 'X'
    end

    it "clears a single stop with TBC (CSI g, mode 0)" do
      em = emu(20, 2)
      em.feed "\e[1;9H\e[g" # cursor to col 8, clear the stop there
      em.feed "\r\tZ"       # HT from col 0 now skips the removed stop -> col 16
      em.lines[0][16].char.should eq 'Z'
    end

    it "advances multiple stops with CHT (CSI I)" do
      em = emu(20, 2)
      em.feed "\e[2IQ" # CHT 2: col 0 -> 8 -> 16
      em.lines[0][16].char.should eq 'Q'
    end

    it "moves back to the previous stop with CBT (CSI Z)" do
      em = emu(20, 2)
      em.feed "\e[1;17H\e[ZY" # cursor at col 16, CBT 1 -> col 8, print Y
      em.lines[0][8].char.should eq 'Y'
    end
  end

  describe "repeat (REP / CSI b)" do
    it "repeats the last printed glyph n times" do
      # ncurses emits REP on a terminal whose terminfo has `rep` (xterm-256color:
      # `rep=\E[%p1%db`) to draw a run of one glyph — e.g. a horizontal rule — in a
      # few bytes. `CSI Pn b` must re-emit the preceding character Pn more times.
      em = emu
      em.feed "-\e[3b" # one '-' then REP 3 -> four dashes total
      row(em, 0).should eq "----"
      em.cursor_x.should eq 4
    end

    it "defaults to repeating once when the count is omitted" do
      em = emu
      em.feed "Q\e[b"
      row(em, 0).should eq "QQ"
      em.cursor_x.should eq 2
    end

    it "is a no-op before any graphic character has been printed" do
      em = emu
      em.feed "\e[5bZ" # REP with no preceding glyph: ignored; Z prints at col 0
      row(em, 0).should eq "Z"
      em.cursor_x.should eq 1
    end

    it "caps an adversarial huge repeat count at the grid area" do
      # `CSI 99999999 b` must not spin O(n): the count is capped at cols*rows, past
      # which the screen is already full of the glyph. (Must return promptly and
      # leave the grid full and the cursor in bounds, not loop ~10^8 times.)
      em = emu(4, 2)
      em.feed "x\e[99999999b"
      row(em, 0).should eq "xxxx"
      em.cursor_x.should be < em.cols
      em.cursor_y.should be < em.rows
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

  describe "insert mode (IRM / CSI 4 h)" do
    it "inserts printed glyphs at the cursor, shifting the rest of the line right" do
      # IRM is the ANSI (non-private) mode 4 — terminfo smir/rmir. With it on, a
      # printed character is inserted (the tail shifts right, overflow dropped)
      # instead of overwriting the cell under the cursor. A child that edits a
      # line with the insert-character capability relies on this.
      em = emu(10, 2)
      em.feed "ABC"   # row0 = "ABC"
      em.feed "\e[H"  # cursor home (row 0, col 0)
      em.feed "\e[4h" # IRM on
      em.feed "X"     # insert X at col 0: "ABC" shifts right
      row(em, 0).should eq "XABC"
      em.cursor_x.should eq 1

      # IRM off (CSI 4 l) returns to overwrite: the next glyph clobbers in place.
      em.feed "\e[4l"
      em.feed "Y" # overwrites the 'A' now at col 1
      row(em, 0).should eq "XYBC"
    end
  end
end
