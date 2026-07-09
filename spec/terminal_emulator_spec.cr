require "./spec_helper"

include Crysterm

# Behaviour specs for the VT100/xterm-subset `TerminalEmulator`. Pure (depends
# only on `Attr` and `Screen.attr2code`), so exercised directly with no `Window`/PTY.

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
      # DEL is a fill/padding control byte; must not be written into the grid nor
      # advance the cursor (it's `>= 0x20`, so a naive printable test would leak it).
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
      # With autowrap off, writing past the last column must stick the cursor
      # there and overwrite, never wrap/scroll to the next line.
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

    it "moves right with HPR (ECMA-48 CSI a), like CUF" do
      # HPR (`CSI Ps a`) is the ECMA-48 twin of CUF — vttest's ISO-6429 HPR test
      # draws a box with it; without it the cursor never advanced and the *'s
      # piled up at the left margin.
      em = emu
      em.feed "A\e[3aB" # A@0; HPR 3 → col 4; B@4
      row(em, 0).should eq "A   B"
      em.cursor_x.should eq 5
    end

    it "moves down with VPR (ECMA-48 CSI e), like CUD" do
      em = emu
      em.feed "A\e[2eB" # A@(0,0); VPR 2 → row 2 (col unchanged = 1); B@(2,1)
      em.cursor_y.should eq 2
      em.lines[2][1].char.should eq 'B'
    end

    it "clears the deferred wrap on CNL/CPL/VPA cursor moves" do
      # An explicit cursor move (CNL 'E', CPL 'F', VPA 'd') must cancel a pending
      # wrap, like CUU/CUD/CUP — otherwise the next char triggers a spurious
      # line-feed (and, for VPA, the wrong column).
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
      # The VT500 parser aborts in-progress state on ESC (except string OSC/DCS
      # states). A half-emitted CSI interrupted by a fresh one
      # (`CSI 1 ESC [ 2;3 H X`) must parse the new CSI, not leak `[`/params as text.
      em = emu
      em.feed "\e[1\e[2;3HX" # incomplete "CSI 1", then a full CUP to row 2 col 3
      em.lines[1][2].char.should eq 'X'
      row(em, 0).should eq "" # nothing leaked onto the first row
    end

    it "swallows the final byte of ESC #/SP/% intermediate escapes" do
      # `ESC # n` (DECALN/double-width line), `ESC SP F` (S7C1T), `ESC % G`
      # (UTF-8 select) are 3-byte sequences; unimplemented, but the final byte
      # must be consumed, not printed (e.g. `ESC # 6` would leak a spurious '6').
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
      # `CSI > 4 ; 2 m` is xterm's modifyOtherKeys (sent by vim/neovim/tmux at
      # startup), not an SGR change. Misreading it as SGR treated `4` as underline,
      # wrongly underlining every glyph until the next reset.
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
      # `CSI > Pn u` / `CSI < Pn u` / `CSI = … u` push/pop/set Kitty keyboard
      # protocol flags — NOT SCORC. Treating a prefixed `u` as restore-cursor
      # yanked the cursor to the last saved position. Plain `CSI s`/`CSI u` must
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

    it "leaves scrollback intact when ED 2 blanks the visible rows in place" do
      # ED 2 now blanks each visible row in place (recycling its storage) rather
      # than replacing it with a fresh array. Visible rows are never aliased by
      # scrollback, so the history above @ybase must be untouched.
      em = emu(4, 2)
      em.feed "L0\r\nL1\r\nL2\r\nL3" # L0/L1 -> scrollback; L2/L3 visible
      em.ybase.should eq 2
      em.feed "\e[2J" # clear the visible window
      row(em, 0).should eq ""
      row(em, 1).should eq ""
      em.lines[0].map(&.char).join.delete('\u0000').rstrip.should eq "L0"
      em.lines[1].map(&.char).join.delete('\u0000').rstrip.should eq "L1"
    end

    it "drops only the scrollback on ED 3, leaving the visible screen intact" do
      # `CSI 3 J` (xterm "Erase Saved Lines") must discard scrollback only,
      # never the visible page.
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
      # DECSC saves the active charset with the cursor; DECRC restores both. With
      # G0 special saved by ESC 7 then reset to ASCII, ESC 8 must bring the
      # line-drawing designation back, so the second 'q' renders as '─' ("──"),
      # not the literal ASCII 'q'.
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
      # Growing the window while on the alt screen must not leave the restored
      # main screen scrolling inside the old, smaller scroll region.
      em = emu(4, 4)
      em.feed "\e[1;1HX"  # X at row 0 of the main buffer
      em.feed "\e[?1049h" # enter alt
      em.resize(4, 6)     # window grows while on the alt screen
      em.feed "\e[?1049l" # leave alt -> main buffer restored
      # With a full-screen region (0..5) LF from row 3 just advances; with a
      # stale region (0..3) it would scroll row 0 (the "X") off the top.
      em.feed "\e[4;1H\n"
      em.cursor_y.should eq 4
      row(em, 0).should eq "X"
    end

    it "1049 shares the per-buffer DECSC slot (xterm): ESC 8 after 1049l sees the 1049-saved cursor" do
      # vttest's alt-screen "cursor save/restore" check. In xterm the 1048/1049
      # cursor save uses the main buffer's DECSC slot, so `1049h` overwrites an
      # earlier `ESC 7`; a later `ESC 8` then restores the 1049-saved position,
      # not the stale `ESC 7` one.
      em = emu(10, 24)
      io = IO::Memory.new
      em.output = io
      em.feed "\e[7;5H\e7" # DECSC saves (row 7, col 5)
      em.feed "\e[23;1H"   # move to (row 23, col 1)
      em.feed "\e[?1049h"  # enter alt — saves the cursor into the same slot
      em.feed "\e[?1049l"  # leave alt — restores it
      em.feed "\e8"        # DECRC: must yield the 1049-saved (23,1), not (7,5)
      em.feed "\e[6n"
      io.to_s.should eq "\e[23;1R"
    end

    it "keeps the DECSC save slot independent between main and alt buffers" do
      # A DECSC on the alt screen must not clobber the main screen's saved cursor.
      em = emu(10, 24)
      io = IO::Memory.new
      em.output = io
      em.feed "\e[3;3H\e7" # main: DECSC saves (row 3, col 3)
      em.feed "\e[?47h"    # enter alt (no cursor save)
      em.feed "\e[9;9H\e7" # alt: DECSC saves (row 9, col 9) in the ALT slot
      em.feed "\e[?47l"    # leave alt (no cursor restore)
      em.feed "\e8"        # DECRC in main: restores the MAIN slot (3,3)
      em.feed "\e[6n"
      io.to_s.should eq "\e[3;3R"
    end

    it "does not accumulate scrollback while on the alternate screen" do
      # The alt screen has no scrollback: scrolling past the bottom must not grow
      # @ybase/@lines nor expose bogus history to scrollback navigation.
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
      # LF at the bottom row must bring up a fresh blank line, not the orphaned
      # L3 that fell off the bottom on the shrink.
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
      # `CSI 99999 L` must not spin O(n·height): count is capped to the lines
      # from cursor to region bottom, beyond which the region is just blanked.
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
      # Per ECMA-48, IL/DL move the active position to column 0; must not stay
      # at the prior column.
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

    it "recycles the scrolled-off line as a full-width blank in a partial scroll region" do
      # Scrolling a partial region (one that excludes a status line) now recycles
      # the discarded line's storage as the fresh blank instead of allocating.
      # The recycled line must be blank across every column at the current width.
      em = emu(4, 4)
      4.times { |i| em.feed "\e[#{i + 1};1HL#{i}" } # L0..L3
      em.feed "\e[1;3r"                             # scroll region rows 1..3 (0-based 0..2); row 3 excluded
      em.feed "\e[3;1H"                             # cursor to the region bottom (0-based row 2)
      em.feed "\n"                                  # LF at the region bottom scrolls the region up
      row(em, 0).should eq "L1"
      row(em, 1).should eq "L2"
      row(em, 2).should eq ""   # recycled blank line
      row(em, 3).should eq "L3" # outside the region: untouched
      recycled = em.lines[em.ydisp + 2]
      recycled.size.should eq 4
      recycled.all? { |c| c.char == ' ' }.should be_true
    end

    it "caps an adversarial huge SU count at the region height" do
      # `CSI 99999999 S` must not spin O(n) or push ~n lines toward the scrollback
      # limit: count is capped at the region height (4 lines into scrollback here).
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
      # CUU/CUD stop at the scroll region's top/bottom margin when the cursor
      # starts inside it. A naive clamp to the screen edges (0 / rows-1) lets
      # the cursor escape the region.
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
      # `CSI ? Pm r` is XTRESTORE (restore DEC private mode values), counterpart
      # to the `CSI ? Pm s` XTSAVE the 's' handler already ignores. Falling
      # through to DECSTBM misread e.g. `CSI ? 7 r` as a top margin and homed the
      # cursor, corrupting the scroll region. Must be a no-op (saved modes aren't tracked).
      em = emu(10, 10)
      em.feed "\e[6;4HX"      # park the cursor at 0-based row 5, col 3
      em.cursor_x.should eq 4 # after printing 'X'
      em.cursor_y.should eq 5
      em.feed "\e[?7r"        # XTRESTORE autowrap: must NOT touch the scroll region
      em.cursor_x.should eq 4 # real DECSTBM would have homed to (0,0)
      em.cursor_y.should eq 5
      # Region intact: CUD walks to the screen bottom (row 9), not a bogus margin.
      em.feed "\e[20B"
      em.cursor_y.should eq 9
    end
  end

  describe "reverse index (RI / ESC M)" do
    it "clears the deferred (last-column) wrap so the next glyph overwrites at the cursor" do
      # RI must cancel a pending last-column wrap, like its mirror IND (LF) and
      # every CSI cursor move. A stale `@wrap_pending` would make the glyph
      # printed right after RI spuriously wrap instead of overwriting.
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
      # xterm clamps a DECSTBM bottom exceeding the screen to the last row and
      # still installs the region rather than rejecting the request. Rejecting
      # would leave a stale pre-resize region in place after e.g. SIGWINCH.
      em = emu(4, 4)
      em.feed "\e[1;2r"  # first install a small region: 0-based rows 0..1
      em.feed "\e[1;1HA" # 'A' at row 0

      # Oversized DECSTBM (bottom 99 > 4 rows): buggy code drops it, leaving the
      # 0..1 region; fixed code clamps to the full 0..3 region.
      em.feed "\e[1;99r"

      # Cursor on the *old* region's bottom margin (row 1), then LF. Stale small
      # region scrolls (loses row 0's 'A'); full region just advances to row 2.
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
      # Must echo the origin-relative row (1), not the absolute row (2).
      io.to_s.should eq "\e[1;1R"
    end
  end

  describe "DECREQTPARM (CSI Ps x)" do
    it "answers argument 0 with a DECREPTPARM report (sol = 2)" do
      em = emu
      io = IO::Memory.new
      em.output = io
      em.feed "\e[0x"
      io.to_s.should eq "\e[2;1;1;128;128;1;0x"
    end

    it "answers argument 1 with sol = 3" do
      em = emu
      io = IO::Memory.new
      em.output = io
      em.feed "\e[1x"
      io.to_s.should eq "\e[3;1;1;128;128;1;0x"
    end

    it "does not answer other arguments" do
      em = emu
      io = IO::Memory.new
      em.output = io
      em.feed "\e[2x"
      io.to_s.should eq ""
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
      # Sixel-shaped DCS payload begins '0;…' — must NOT fire on_title.
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
      # Custom stop at column 4: HT must land there, not a hardcoded 8-col boundary.
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
      # ncurses emits REP (terminfo `rep`) to draw a run of one glyph in few
      # bytes. `CSI Pn b` must re-emit the preceding character Pn more times.
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
      # `CSI 99999999 b` must not spin O(n): count is capped at cols*rows, past
      # which the screen is already full.
      em = emu(4, 2)
      em.feed "x\e[99999999b"
      row(em, 0).should eq "xxxx"
      em.cursor_x.should be < em.cols
      em.cursor_y.should be < em.rows
    end
  end

  describe "oversized CSI parameters" do
    it "does not overflow on a CSI parameter larger than Int32" do
      # A numeric CSI parameter beyond Int32::MAX must not raise OverflowError
      # (would silently tear down the reader fiber's session). Out-of-range reads
      # as 0, like the old `to_i? || 0`, so the move falls back to its default.
      em = emu(10, 4)
      em.feed "\e[9999999999;9999999999HX" # CUP with both fields overflowing
      em.cursor_x.should be < em.cols
      em.cursor_y.should be < em.rows
      # In-range CUP still positions exactly (regression guard).
      em.feed "\e[2;3HY"
      em.lines[1][2].char.should eq 'Y'
    end

    it "does not overflow on an oversized private-mode (SGR / set_mode) parameter" do
      em = emu
      # `each_csi_param` (used by set_mode) shares the accumulator; a giant mode
      # number must be swallowed, not crash.
      em.feed "\e[?9999999999h"
      em.feed "\e[9999999999mZ" # oversized SGR param: ignored, char still prints
      em.lines[0][0].char.should eq 'Z'
    end
  end

  describe "insert mode (IRM / CSI 4 h)" do
    it "inserts printed glyphs at the cursor, shifting the rest of the line right" do
      # IRM is ANSI mode 4 (terminfo smir/rmir). With it on, a printed character
      # is inserted (tail shifts right, overflow dropped) instead of overwriting.
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

  describe "DECALN (ESC # 8)" do
    it "fills the whole screen with E and homes the cursor" do
      # DEC screen-alignment test — the primitive vttest's cursor-movement test
      # builds its frame of E's from (fill screen, then erase all but a border).
      em = emu(4, 3)
      em.feed "\e[2;2Hx" # move off home, print, so the fill/home is observable
      em.feed "\e#8"
      3.times { |y| row(em, y).should eq "EEEE" }
      em.cursor_x.should eq 0
      em.cursor_y.should eq 0
    end

    it "swallows the double-size line selectors (ESC # 3/4/5/6) with no output" do
      em = emu(4, 2)
      em.feed "\e#3Z" # DECDHL top half (unimplemented) then print Z
      row(em, 0).should eq "Z"
    end
  end

  describe "control characters inside CSI sequences" do
    # The VT500 parser executes a C0 control the instant it appears mid-sequence,
    # then resumes the CSI — it does NOT abort it. vttest's "cursor-control
    # characters inside ESC sequences" screen relies on this.
    it "executes an embedded BS then resumes the CSI (CSI 2 <BS> C)" do
      em = emu(10, 1)
      em.feed "A\e[2\bCB" # A@0; CSI 2, BS→col0, CUF 2→col2; B@2
      row(em, 0).should eq "A B"
      em.cursor_x.should eq 3
    end

    it "executes an embedded CR then resumes the CSI (CSI <CR> 3 C)" do
      em = emu(10, 1)
      em.feed "AB\e[\r3CX" # AB; CSI, CR→col0, param 3, CUF 3→col3; X@3
      row(em, 0).should eq "AB X"
      em.cursor_x.should eq 4
    end

    it "aborts the CSI on CAN (0x18), printing the trailing byte as text" do
      em = emu(10, 1)
      em.feed "A\e[5\u{18}C" # A@0; CSI 5 aborted by CAN; 'C' printed literally @1
      row(em, 0).should eq "AC"
      em.cursor_x.should eq 2
    end
  end
end
