require "./spec_helper"

include Crysterm

# Regression specs for BUGS12 findings #27, #28 and #29
# (src/widget_terminal_emulator.cr). The emulator is pure (depends only on
# Attr), so it is exercised directly with no Window/PTY — matching
# spec/terminal_emulator_spec.cr and spec/bugs11_terminal_emulator_spec.cr.

private DFL = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)

private def emu(cols = 20, rows = 4)
  Crysterm::TerminalEmulator.new(cols, rows, DFL)
end

# Char of cell `x` on row `y`.
private def cell_char(em, x, y)
  em.lines[em.ydisp + y][x].char
end

describe Crysterm::TerminalEmulator do
  describe "RIS keeps post-reset input (#27)" do
    # `feed` peels the chunk's incomplete-UTF-8 tail into `@leftover` *before*
    # parsing. When RIS (`ESC c`) executes mid-chunk, `@leftover` holds stream
    # bytes positioned AFTER the `ESC c` — legitimate post-reset input.
    # `full_reset` must not discard them.
    it "preserves a straddling UTF-8 lead byte across ESC c" do
      em = emu
      # `ESC c` then the lead byte of `é` (C3 A9); C3 is incomplete so it lands
      # in @leftover, and RIS runs while it is buffered.
      em.feed Bytes[0x1b, 'c'.ord.to_u8, 0xC3]
      # The continuation byte completes `é` — only possible if the lead survived.
      em.feed Bytes[0xA9]
      cell_char(em, 0, 0).should eq 'é'
    end

    it "still clears the screen on RIS" do
      em = emu
      em.feed "X"
      em.feed Bytes[0x1b, 'c'.ord.to_u8]
      cell_char(em, 0, 0).should eq ' '
      em.x.should eq 0
      em.y.should eq 0
    end
  end

  describe "DEL inside a sequence is ignored (#28)" do
    # DEL (0x7f) is neither an intermediate/parameter/final byte; the VT500
    # parser ignores it mid-sequence. Without the guard it reached dispatch_csi
    # (or handle_esc's else) as a spurious final byte, aborting the sequence.
    it "does not abort a CSI sequence (CSI 3 DEL C moves 3 right)" do
      em = emu
      em.feed "\e[3\u{7f}C" # CUF 3 with a DEL spliced before the final 'C'
      em.x.should eq 3
      cell_char(em, 0, 0).should eq ' ' # 'C' did not leak into the grid
    end

    it "does not abort an ESC sequence (ESC DEL c still runs RIS)" do
      em = emu
      em.feed "X"
      em.feed "\e\u{7f}c"               # RIS with a DEL between ESC and 'c'
      cell_char(em, 0, 0).should eq ' ' # screen cleared, 'c' did not print
      cell_char(em, 1, 0).should eq ' '
      em.x.should eq 0
    end
  end

  describe "CHT/CBT counts are clamped (#29)" do
    # The cursor can't cross more tab stops than there are columns, so a huge
    # CSI parameter must be clamped to @cols instead of spinning O(n·cols).
    it "clamps a huge CHT (CSI 99999999 I) to the last column" do
      em = emu(cols: 20)
      em.feed "\e[99999999I"
      em.x.should eq 19 # last column, reached quickly (not after 99999999 iters)
    end

    it "clamps a huge CBT (CSI 99999999 Z) to column 0" do
      em = emu(cols: 20)
      em.feed "\e[20G" # park cursor at the last column (1-based param)
      em.x.should eq 19
      em.feed "\e[99999999Z" # back-tab far more than there are stops
      em.x.should eq 0
    end
  end
end
