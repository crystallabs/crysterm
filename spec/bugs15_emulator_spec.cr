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
