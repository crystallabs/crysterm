require "./spec_helper"

include Crysterm

# Group F (allocation reduction) behaviour specs for `TerminalEmulator`:
#   F1 — in-place UTF-8 decode of multibyte glyphs (no `String` remainder copy)
#   F2 — charset-designation escape sets the right G-index
#   F3 — in-place OSC title code parse (only 0/1/2 fire on_title)
#   F4 — ED 3 (Erase Saved Lines) drops scrollback, keeps the visible page
#
# Pure emulator, no `Window`/PTY.

private DFL = Crysterm::Attr.pack(0, Crysterm::Attr::COLOR_DEFAULT, Crysterm::Attr::COLOR_DEFAULT)

private def emu(cols = 10, rows = 4)
  Crysterm::TerminalEmulator.new(cols, rows, DFL)
end

private def row(em, y)
  em.lines[em.ydisp + y].map(&.char).join.delete('\0').rstrip
end

describe "TerminalEmulator Group F" do
  describe "F1 — multibyte UTF-8 output" do
    it "renders non-Latin (2- and 3-byte) glyphs from a UTF-8 chunk" do
      em = emu
      em.feed "héllo" # 'é' is 2-byte UTF-8
      row(em, 0).should eq "héllo"
      em.cursor_x.should eq 5

      em = emu
      em.feed "αβγ" # Greek, 2-byte each
      row(em, 0).should eq "αβγ"
    end

    it "renders 3-byte box-drawing glyphs written directly (not via charset)" do
      em = emu
      em.feed "─┼─" # U+2500 / U+253C, 3-byte UTF-8
      row(em, 0).should eq "─┼─"
    end

    it "renders a 4-byte glyph (emoji, wide) and advances two columns" do
      em = emu
      em.feed "😀X" # U+1F600 is wide (2 cols)
      # Column 0 holds the emoji, column 1 the continuation NUL, 'X' at column 2.
      em.lines[0][0].char.should eq '😀'
      em.lines[0][2].char.should eq 'X'
      em.cursor_x.should eq 3
    end

    it "resumes the ASCII fast loop after each multibyte glyph" do
      em = emu(20, 2)
      em.feed "a→b→c" # ASCII / 3-byte / ASCII interleaved
      row(em, 0).should eq "a→b→c"
    end

    it "handles a multibyte glyph split across two feeds (leftover reassembly)" do
      em = emu
      bytes = "€".to_slice # U+20AC, 3 bytes
      em.feed bytes[0, 2]  # incomplete
      row(em, 0).should eq ""
      em.feed bytes[2, 1] # completes the glyph
      row(em, 0).should eq "€"
    end

    it "processes a control byte immediately after a multibyte glyph" do
      em = emu
      em.feed "é\r\nx" # CR/LF must still be seen as controls after 'é'
      row(em, 0).should eq "é"
      row(em, 1).should eq "x"
    end

    it "emits U+FFFD for a stray continuation byte and keeps decoding" do
      em = emu
      em.feed Bytes[0x41, 0x80, 0x42] # 'A', lone continuation, 'B'
      row(em, 0).should eq "A�B"
    end
  end

  describe "F2 — charset designation escape" do
    it "designates G0 special via ESC ( 0 (index 0)" do
      em = emu
      em.feed "\e(0q\e(BX" # G0=special: 'q'->'─', then ASCII
      row(em, 0).should eq "─X"
    end

    it "designates G1 special via ESC ) 0 (index 1), invoked with SO" do
      em = emu
      em.feed "\e)0\x0Eq" # G1=special, SO invokes G1
      row(em, 0).should eq "─"
    end

    it "routes ESC * (index 2) and ESC + (index 3) without affecting G0/G1 rendering" do
      # G2/G3 are tracked-but-unused; designating them must not turn G0 special.
      em = emu
      em.feed "\e*0q" # designate G2 special, GL still G0(ASCII)
      row(em, 0).should eq "q"
      em = emu
      em.feed "\e+0q" # designate G3 special, GL still G0(ASCII)
      row(em, 0).should eq "q"
    end
  end

  describe "F3 — OSC title parsing" do
    it "reports OSC 0 and OSC 2 titles" do
      em = emu
      titles = [] of String
      em.on_title = ->(t : String) { titles << t; nil }
      em.feed "\e]0;hello\a"   # BEL-terminated
      em.feed "\e]2;world\e\\" # ST-terminated
      titles.should eq ["hello", "world"]
    end

    it "reports an OSC 1 (icon name) title" do
      em = emu
      titles = [] of String
      em.on_title = ->(t : String) { titles << t; nil }
      em.feed "\e]1;icon\a"
      titles.should eq ["icon"]
    end

    it "ignores OSC 7 (cwd) and OSC 133 (prompt marks)" do
      em = emu
      titles = [] of String
      em.on_title = ->(t : String) { titles << t; nil }
      em.feed "\e]7;file:///home/user\a"
      em.feed "\e]133;A\a"
      titles.should be_empty
    end

    it "does not fire on an empty code (leading ';')" do
      em = emu
      titles = [] of String
      em.on_title = ->(t : String) { titles << t; nil }
      em.feed "\e];notitle\a"
      titles.should be_empty
    end

    it "does not fire when no ';' terminator is present" do
      em = emu
      titles = [] of String
      em.on_title = ->(t : String) { titles << t; nil }
      em.feed "\e]0\a"
      titles.should be_empty
    end

    it "reports a title containing multibyte text" do
      em = emu
      titles = [] of String
      em.on_title = ->(t : String) { titles << t; nil }
      em.feed "\e]2;héllo→\a"
      titles.should eq ["héllo→"]
    end
  end

  describe "F4 — ED 3 (Erase Saved Lines)" do
    it "drops scrollback but keeps the visible page intact" do
      em = emu(10, 3)
      # Produce scrollback by scrolling past the window height.
      em.feed "L0\nL1\nL2\nL3\nL4"
      em.ybase.should be > 0
      visible0 = row(em, 0)
      visible1 = row(em, 1)
      visible2 = row(em, 2)

      em.feed "\e[3J" # ED 3
      em.ybase.should eq 0
      em.ydisp.should eq 0
      em.lines.size.should eq 3 # exactly the visible page
      row(em, 0).should eq visible0
      row(em, 1).should eq visible1
      row(em, 2).should eq visible2
    end
  end
end
