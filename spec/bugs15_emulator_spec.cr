require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 findings #26, #56, #57 and #58
# (src/widget_terminal_emulator.cr). The emulator is pure (depends only on
# Attr), so it is exercised directly with no Window/PTY — matching
# spec/terminal_emulator_spec.cr and spec/bugs12_terminal_emulator_spec.cr.

private DFL = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)

private def emu(cols = 6, rows = 4)
  Crysterm::TerminalEmulator.new(cols, rows, DFL)
end

# Char of cell `x` on row `y`.
private def cell_char(em, x, y)
  em.lines[em.ydisp + y][x].char
end

describe Crysterm::TerminalEmulator do
  describe "print_char repairs split wide-glyph pairs (#26)" do
    # Writing onto the trailing (CONTINUATION) half must blank the orphaned lead,
    # else the grid still carries a 2-wide lead with no continuation. The visible
    # "X invisible" symptom is gated on the window's full_unicode mode, but the
    # emulator grid corruption exists regardless — assert at the grid level.
    it "blanks the orphaned lead when overwriting a continuation cell" do
      em = emu
      em.feed "あ"       # wide lead at col0, CONTINUATION at col1, cursor → col2
      em.feed "\e[1;2H" # CUP row1 col2 → 0-based col1 (the trailing half)
      em.feed "X"
      cell_char(em, 0, 0).should eq ' ' # lead blanked (was stale 'あ')
      cell_char(em, 1, 0).should eq 'X'
    end

    # Writing a narrow char onto a wide LEAD must blank the now-orphaned trailing
    # CONTINUATION sentinel left one cell to the right.
    it "blanks the orphaned continuation when overwriting a wide lead" do
      em = emu
      em.feed "あ"       # lead col0, CONTINUATION col1
      em.feed "\e[1;1H" # CUP to col0 (the lead)
      em.feed "Y"       # narrow glyph over the lead
      cell_char(em, 0, 0).should eq 'Y'
      cell_char(em, 1, 0).should eq ' ' # was the CONTINUATION sentinel (NUL)
    end
  end

  describe "CSI parameter buffer is capped (#56)" do
    # An unterminated / adversarial CSI with a huge parameter run must not grow
    # @csi_buf without bound (OSC already has OSC_MAX; CSI now has CSI_MAX).
    # Behaviourally: the guard leaves terminator scanning intact, so state
    # recovers and a following sequence parses normally.
    it "handles a very long parameter run and still recovers state" do
      em = emu(cols: 6)
      em.feed "\e[" + ("9" * 100_000) + "C" # CUF with an enormous count
      em.x.should eq 5                      # clamped to the last column
      em.feed "\e[1;1HZ"                    # a following CSI still works
      cell_char(em, 0, 0).should eq 'Z'
    end
  end

  describe "erase_display cancels pending wrap (#57)" do
    # After a row is filled to the last column (deferred wrap pending), ED 0/1/2
    # must ResetWrap like EL, so the next glyph overwrites the cursor cell in
    # place instead of wrapping (and possibly scrolling).
    it "ED 0 does not let a pending wrap fire on the next print" do
      em = emu(cols: 4)
      em.feed "ABCD"  # fills row0, cursor parked at col3 with wrap pending
      em.feed "\e[0J" # erase cursor → end of screen
      em.feed "E"
      cell_char(em, 3, 0).should eq 'E' # overwrote in place
      cell_char(em, 0, 1).should eq ' ' # did NOT wrap to the next row
    end

    it "ED 2 does not let a pending wrap fire on the next print" do
      em = emu(cols: 4)
      em.feed "ABCD"
      em.feed "\e[2J" # erase whole screen (cursor unmoved at col3)
      em.feed "E"
      cell_char(em, 3, 0).should eq 'E'
      cell_char(em, 0, 1).should eq ' '
    end
  end

  describe "DECSC/DECRC save & restore pending wrap (#58)" do
    # DECRC onto the last column with a wrap pending must re-arm the deferred
    # wrap, so the next printable wraps rather than overwriting in place.
    it "re-arms the deferred wrap after ESC 8 restores onto the last column" do
      em = emu(cols: 4)
      em.feed "ABCD"      # cursor parks at col3, wrap pending
      em.feed "\e7"       # DECSC
      em.feed "\e[3;1Hxx" # move away and print (clears wrap pending)
      em.feed "\e8"       # DECRC → back onto col3 with wrap re-armed
      em.feed "E"
      cell_char(em, 3, 0).should eq 'D' # last column untouched
      cell_char(em, 0, 1).should eq 'E' # wrapped to the next row
    end
  end
end

# BUGS15 #26 follow-up: the same wide-glyph pair repairs print_char got must
# also run at the boundaries of EL/ECH (erase_in_line), DCH (delete_chars),
# ICH (insert_chars) and the IRM per-char shift — all of which can split a
# pair the same way. Asserted at the grid level, like the print_char cases.
describe "editing-op boundaries repair split wide-glyph pairs (#26 follow-up)" do
  describe "erase_in_line (EL / ECH)" do
    it "blanks the orphaned lead when the erased range starts on a continuation" do
      em = emu
      em.feed "あX"                      # lead col0, CONTINUATION col1, X col2
      em.feed "\e[1;2H"                 # cursor onto the trailing half
      em.feed "\e[K"                    # EL 0: erase cursor → eol
      cell_char(em, 0, 0).should eq ' ' # lead blanked, not left 2-wide
      cell_char(em, 1, 0).should eq ' '
    end

    it "blanks the orphaned continuation when the erased range ends on a lead" do
      em = emu
      em.feed "あ"
      em.feed "\e[1;1H"
      em.feed "\e[1K" # EL 1: erase sol → cursor (col0, the lead only)
      cell_char(em, 0, 0).should eq ' '
      cell_char(em, 1, 0).should eq ' ' # was CONTINUATION, lead gone
    end

    it "repairs both halves when ECH erases just the trailing half" do
      em = emu
      em.feed "あ"
      em.feed "\e[1;2H"
      em.feed "\e[1X" # ECH 1 at the continuation cell
      cell_char(em, 0, 0).should eq ' '
      cell_char(em, 1, 0).should eq ' '
    end
  end

  describe "delete_chars (DCH)" do
    it "blanks the orphaned lead when deletion starts on a continuation" do
      em = emu
      em.feed "あB"      # lead 0, CONTINUATION 1, B 2
      em.feed "\e[1;2H" # cursor onto the trailing half
      em.feed "\e[1P"   # delete it; B shifts left into col1
      cell_char(em, 0, 0).should eq ' '
      cell_char(em, 1, 0).should eq 'B'
    end

    it "blanks the bare continuation pulled up when deletion ends inside a pair" do
      em = emu
      em.feed "Aあ"      # A 0, lead 1, CONTINUATION 2
      em.feed "\e[1;2H" # cursor onto the lead
      em.feed "\e[1P"   # delete the lead; its continuation shifts into col1
      cell_char(em, 0, 0).should eq 'A'
      cell_char(em, 1, 0).should eq ' ' # not a floating CONTINUATION
    end
  end

  describe "insert_chars (ICH)" do
    it "repairs both sides of a gap opened inside a pair" do
      em = emu
      em.feed "あ"
      em.feed "\e[1;2H"                 # cursor onto the trailing half
      em.feed "\e[1@"                   # open 1 blank cell there
      cell_char(em, 0, 0).should eq ' ' # lead left of the gap
      cell_char(em, 1, 0).should eq ' ' # the gap itself
      cell_char(em, 2, 0).should eq ' ' # shifted CONTINUATION, lead gone
    end

    it "blanks the bare lead left in the last cell when the shift clips a pair" do
      em = emu           # 6 cols
      em.feed "\e[1;5Hあ" # lead col4, CONTINUATION col5
      em.feed "\e[1;1H"
      em.feed "\e[1@" # shift right: lead → col5, continuation dropped
      cell_char(em, 5, 0).should eq ' '
    end
  end

  describe "IRM (insert mode) per-char shift" do
    it "blanks the bare lead left in the last cell when printing clips a pair" do
      em = emu           # 6 cols
      em.feed "\e[1;5Hあ" # lead col4, CONTINUATION col5
      em.feed "\e[4h"    # IRM on
      em.feed "\e[1;1HZ" # insert-print at col0: shift clips the pair
      cell_char(em, 0, 0).should eq 'Z'
      cell_char(em, 5, 0).should eq ' '
    end
  end
end
