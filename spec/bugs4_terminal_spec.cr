require "./spec_helper"

include Crysterm

# Regression spec for the BUGS4 terminal-emulator fix: SU (`CSI Ps S`) and SD
# (`CSI Ps T`) must only act on a *plain* CSI. A prefixed form is a different
# command — `CSI ? Pi;Pa;Pv S` is XTSMGRAPHICS (a common sixel-capability probe
# at startup) and `CSI > Pm T` resets xterm title modes — and must NOT scroll the
# screen. Without the `@csi_prefix.nil?` gate, the probe's first numeric field was
# read as a line count and the live screen scrolled.

private def default_attr : Int64
  Attr.pack(0_i64, -1, -1)
end

private def emulator(cols = 10, rows = 4) : TerminalEmulator
  TerminalEmulator.new cols, rows, default_attr
end

private def row_text(em : TerminalEmulator, y = 0) : String
  em.lines[em.ybase + y].map(&.char).join.rstrip(' ')
end

private def snapshot(em : TerminalEmulator, rows = 3) : Array(String)
  (0...rows).map { |y| row_text(em, y) }
end

describe "TerminalEmulator SU/SD prefix gating (BUGS4)" do
  it "does not scroll on an XTSMGRAPHICS probe (CSI ? ... S)" do
    em = emulator
    em.feed "AAAA\r\nBBBB\r\nCCCC"
    before = snapshot em

    em.feed "\e[?2;1;0S" # sixel-capability probe — must be a no-op for the grid
    snapshot(em).should eq before
  end

  it "does not scroll on a prefixed SD (CSI > Pm T)" do
    em = emulator
    em.feed "AAAA\r\nBBBB\r\nCCCC"
    before = snapshot em

    em.feed "\e[>0T"
    snapshot(em).should eq before
  end

  it "still scrolls up on a plain SU (CSI Ps S) — no regression" do
    em = emulator
    em.feed "AAAA\r\nBBBB\r\nCCCC"

    em.feed "\e[1S" # plain SU: scroll the whole screen up one line
    row_text(em, 0).should eq "BBBB"
    row_text(em, 1).should eq "CCCC"
  end
end
