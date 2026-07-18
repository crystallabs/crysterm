require "./spec_helper"

include Crysterm

# Regression specs for BUGS15 findings #93 and #94
# (src/widget_terminal_emulator.cr, handle_osc). The emulator is pure
# (depends only on Attr), so it is exercised directly with no Window/PTY —
# matching spec/terminal_emulator_spec.cr's "OSC title vs. DCS/PM/APC
# strings" examples and spec/bugs15_emulator_spec.cr.

private DFL = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)

private def emu(cols = 20, rows = 4)
  Crysterm::TerminalEmulator.new(cols, rows, DFL)
end

# Char of cell `x` on row `y`.
private def cell_char(em, x, y)
  em.lines[em.ydisp + y][x].char
end

# Row 0 as a plain string, trimmed of trailing blanks, for readable asserts.
private def row0(em)
  String.build do |s|
    (0...em.cols).each { |x| s << cell_char(em, x, 0) }
  end.rstrip
end

describe Crysterm::TerminalEmulator do
  describe "CAN/SUB abort an in-flight OSC/DCS string (#93)" do
    it "CAN (0x18) aborts an OSC and resumes normal output" do
      em = emu
      em.feed "\e]0;t\u{18}hello"
      row0(em).should eq "hello"
    end

    it "SUB (0x1a) aborts an OSC and resumes normal output" do
      em = emu
      em.feed "\e]0;t\u{1a}world"
      row0(em).should eq "world"
    end

    it "CAN aborts a DCS string too" do
      em = emu
      em.feed "\eP0;1;0q\u{18}ABC"
      row0(em).should eq "ABC"
    end

    it "does not fire on_title for a CAN-aborted OSC" do
      em = emu
      titles = [] of String
      em.on_title = ->(t : String) { titles << t; nil }
      em.feed "\e]0;partial-title\u{18}hello"
      titles.should be_empty
      row0(em).should eq "hello"
    end
  end

  describe "BEL inside a DCS/SOS/PM/APC string is inert payload, not a terminator (#94)" do
    it "does not leak a BEL-containing DCS passthrough payload (tmux wrapper)" do
      em = emu
      # tmux-style DCS passthrough: DCS tmux; <doubled-ESC payload> ST, where
      # the wrapped payload itself contains an OSC-with-BEL. Real xterm
      # swallows the whole thing to the outer ST; nothing should print.
      em.feed "\ePtmux;\e\e]0;t\amore\e\\"
      row0(em).should eq ""
    end

    it "treats BEL inside an APC string as payload, only ST terminates" do
      em = emu
      em.feed "\e_payload\awith-bel\e\\Z"
      row0(em).should eq "Z"
    end

    it "still lets BEL terminate a real OSC (title set, nothing printed)" do
      em = emu
      titles = [] of String
      em.on_title = ->(t : String) { titles << t; nil }
      em.feed "\e]0;hello\a"
      titles.should eq ["hello"]
      row0(em).should eq ""
    end

    it "resumes normal parsing after a BEL-containing DCS reaches its real ST" do
      em = emu
      em.feed "\eP0;1;0q\amid\e\\X"
      row0(em).should eq "X"
    end
  end
end
