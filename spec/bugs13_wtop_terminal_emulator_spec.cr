require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 "Widget top-level" findings W1, W2, W3 and W18
# (src/widget_terminal_emulator.cr). The emulator is pure (depends only on
# Attr), so it is exercised directly with no Window/PTY — matching
# spec/terminal_emulator_spec.cr and spec/bugs12_terminal_emulator_spec.cr.

private DFL = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)

private def emu(cols = 20, rows = 4)
  Crysterm::TerminalEmulator.new(cols, rows, DFL)
end

# Char of cell `x` on row `y`.
private def cell_char(em, x, y)
  em.lines[em.ydisp + y][x].char
end

describe Crysterm::TerminalEmulator do
  describe "W1: large-but-valid CSI parameters don't overflow handlers" do
    # PARAM_ACCUM_MAX only kept the *parser* from overflowing; a value like
    # 2147483639 still reached handlers doing unclamped Int32 adds (`@x + n`),
    # so the OverflowError escaped #feed and wedged the widget (the reader
    # fiber treats an exception as EOF). Fields now clamp at 65535 (xterm's cap).
    it "does not raise on a huge CUF with the cursor away from column 0" do
      em = emu
      em.feed "\e[11G" # park at column 10 (1-based param)
      em.x.should eq 10
      em.feed "\e[2147483639C" # CUF Int32::MAX-ish
      em.x.should eq 19        # clamped to the last column
    end

    it "does not raise on huge CUD/CUP/ECH parameters" do
      em = emu
      em.feed "\e[2147483639B" # CUD
      em.y.should eq 3
      em.feed "\e[2147483639;2147483639H" # CUP
      em.y.should eq 3
      em.x.should eq 19
      em.feed "\e[5G\e[2147483000X" # ECH from column 4: @x + n - 1 add
      em.x.should eq 4              # ECH doesn't move the cursor
    end

    it "does not raise on a huge private-mode parameter list" do
      em = emu
      em.feed "\e[?2147483639h" # each_csi_param path
    end

    it "still parses ordinary parameters exactly" do
      em = emu
      em.feed "\e[3;7H"
      em.y.should eq 2
      em.x.should eq 6
    end
  end

  describe "W2: EL/ICH/DCH/ECH clear the pending autowrap (xterm ResetWrap)" do
    # After printing into the last column, a wrap is pending. xterm's
    # ClearRight/InsertChar/DeleteChar/EraseChars all reset that state, so the
    # next print overwrites the same row instead of wrapping (and scrolling).
    it "EL then print overwrites the current row instead of wrapping" do
      em = emu(cols: 5)
      em.feed "abcde" # fills row 0; wrap now pending
      em.feed "\e[K"  # EL to end of line — resets wrap state
      em.feed "Q"
      cell_char(em, 4, 0).should eq 'Q' # printed on row 0 (at the cursor)
      cell_char(em, 0, 1).should eq ' ' # no wrap onto row 1
      em.y.should eq 0
    end

    it "DCH then print does not wrap" do
      em = emu(cols: 5)
      em.feed "abcde"
      em.feed "\e[1P" # DCH
      em.feed "Q"
      em.y.should eq 0
      cell_char(em, 0, 1).should eq ' '
    end

    it "ICH then print does not wrap" do
      em = emu(cols: 5)
      em.feed "abcde"
      em.feed "\e[1@" # ICH
      em.feed "Q"
      em.y.should eq 0
      cell_char(em, 0, 1).should eq ' '
    end

    it "ECH then print does not wrap" do
      em = emu(cols: 5)
      em.feed "abcde"
      em.feed "\e[1X" # ECH
      em.feed "Q"
      em.y.should eq 0
      cell_char(em, 0, 1).should eq ' '
    end

    it "an ordinary full row still wraps on the next print" do
      em = emu(cols: 5)
      em.feed "abcdeF"
      cell_char(em, 0, 1).should eq 'F'
      em.y.should eq 1
    end
  end

  describe "W3: prefixed SM/RM is not dispatched as plain ANSI set-mode" do
    # `ESC [ = 4 h` is ANSI.SYS window-mode select (common in .ans art), not
    # SM; misreading its `4` as IRM enabled insert mode and garbled all
    # later output.
    it "ESC [ = 4 h does not enable insert mode" do
      em = emu
      em.feed "XYZ\r"
      em.feed "\e[=4h"
      em.feed "A"
      cell_char(em, 0, 0).should eq 'A' # overwrote 'X'
      cell_char(em, 1, 0).should eq 'Y' # 'Y' did NOT shift right
    end

    it "ESC [ > 4 l is ignored too" do
      em = emu
      em.feed "\e[4h" # genuine SM: IRM on
      em.feed "\e[>4l"
      em.feed "XY\r"
      em.feed "A"
      # IRM must still be on (the prefixed RM was not dispatched): 'A' inserts.
      cell_char(em, 0, 0).should eq 'A'
      cell_char(em, 1, 0).should eq 'X'
    end

    it "plain SM/RM still toggles IRM" do
      em = emu
      em.feed "XY\r\e[4h"
      em.feed "A"
      cell_char(em, 0, 0).should eq 'A'
      cell_char(em, 1, 0).should eq 'X' # shifted right by the insert
      em.feed "\r\e[4l"
      em.feed "B"
      cell_char(em, 0, 0).should eq 'B'
      cell_char(em, 1, 0).should eq 'X' # replace mode again
    end

    it "DEC private modes (with ? prefix) still work" do
      em = emu
      em.feed "\e[?7l" # DECAWM off
      em.feed "\e[?7h"
    end
  end

  describe "W18: disabling a non-active mouse encoding doesn't downgrade the active one" do
    it "keeps SGR encoding when the child defensively resets 1005" do
      em = emu
      em.feed "\e[?1006h" # SGR on
      em.mouse_encoding.should eq :sgr
      em.feed "\e[?1005l" # reset UTF-8 encoding — NOT the active one
      em.mouse_encoding.should eq :sgr
      em.feed "\e[?1015l" # reset urxvt — also not active
      em.mouse_encoding.should eq :sgr
    end

    it "still downgrades when the active encoding itself is disabled" do
      em = emu
      em.feed "\e[?1006h"
      em.feed "\e[?1006l"
      em.mouse_encoding.should eq :normal
    end

    it "enable still switches between encodings" do
      em = emu
      em.feed "\e[?1005h"
      em.mouse_encoding.should eq :utf8
      em.feed "\e[?1015h"
      em.mouse_encoding.should eq :urxvt
      em.feed "\e[?1005l" # utf8 not active anymore — no-op
      em.mouse_encoding.should eq :urxvt
      em.feed "\e[?1015l"
      em.mouse_encoding.should eq :normal
    end
  end
end
