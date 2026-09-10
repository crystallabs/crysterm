require "./spec_helper"

include Crysterm

# Behaviour specs for `TerminalEmulator`'s handling of C1 controls and
# zero-width codepoints in the data stream, and the split-pair repair on the
# autowrap pre-wrap blank. The emulator is pure (depends only on Attr), so it
# is exercised directly with no Window/PTY — matching
# spec/terminal_emulator_spec.cr.

describe Crysterm::TerminalEmulator do
  describe "C1 controls in ground state" do
    it "interprets C1 CSI (0x9B, UTF-8 C2 9B) as a CSI introducer" do
      em = emu(cols: 6)
      em.feed "ABCDEF"
      em.feed "\u{9B}2J" # C1 CSI + "2J" → ED 2 (erase display)
      emu_row(em, 0).should eq ""
    end

    it "executes a C1 CSI cursor move like its ESC [ form" do
      em = emu(cols: 6)
      em.feed "\u{9B}2;3HX" # C1 CSI + CUP row 2 col 3
      emu_char(em, 2, 1).should eq 'X'
    end

    it "interprets C1 OSC (0x9D) as a string introducer terminated by BEL" do
      em = emu(cols: 10)
      em.feed "\u{9D}0;title\u{7}Z" # OSC 0 (set title) then a printable
      emu_row(em, 0).should eq "Z"
    end

    it "swallows a C1 DCS (0x90) string payload up to ST" do
      em = emu(cols: 10)
      em.feed "\u{90}q#payload\e\\Z" # DCS … ESC \ then a printable
      emu_row(em, 0).should eq "Z"
    end

    it "executes C1 IND (0x84) like ESC D" do
      em = emu(cols: 6)
      em.feed "ab\u{84}c" # line feed, column preserved
      emu_row(em, 0).should eq "ab"
      emu_char(em, 2, 1).should eq 'c'
    end

    it "executes C1 NEL (0x85) like ESC E" do
      em = emu(cols: 6)
      em.feed "ab\u{85}c" # next line, column 0
      emu_row(em, 0).should eq "ab"
      emu_row(em, 1).should eq "c"
    end

    it "executes C1 RI (0x8D) like ESC M" do
      em = emu(cols: 6)
      em.feed "\e[2;2H\u{8D}X" # cursor to row 2 col 2, reverse index, print
      em.cursor_y.should eq 0
      emu_char(em, 1, 0).should eq 'X'
    end

    it "executes C1 HTS (0x88) like ESC H" do
      em = emu(cols: 10)
      em.feed "\e[1;4H\u{88}\r\tX" # set a stop at col 4, CR, tab lands on it
      emu_char(em, 3, 0).should eq 'X'
    end

    it "drops a stray C1 ST (0x9C) with no string open" do
      em = emu(cols: 6)
      em.feed "a\u{9C}b"
      emu_row(em, 0).should eq "ab"
      em.cursor_x.should eq 2
    end

    it "never stores an unmapped C1 control as a printable cell" do
      em = emu(cols: 6)
      em.feed "a\u{86}b" # SSA: no handler — discarded, no cell, no cursor move
      emu_row(em, 0).should eq "ab"
      em.cursor_x.should eq 2
    end
  end

  describe "zero-width codepoints" do
    it "does not give a combining mark a cell of its own" do
      em = emu(cols: 6)
      em.feed "a\u{0301}b" # combining acute between two glyphs
      emu_row(em, 0).should eq "ab"
      em.cursor_x.should eq 2
    end

    it "keeps ordinary narrow and wide rendering intact" do
      em = emu(cols: 6)
      em.feed "あb" # wide lead + continuation, then a narrow glyph
      emu_char(em, 0, 0).should eq 'あ'
      emu_char(em, 2, 0).should eq 'b'
      em.cursor_x.should eq 3
    end
  end

  describe "autowrap pre-wrap blank over a continuation cell" do
    it "blanks the orphaned lead when the pre-wrap blank lands on a continuation" do
      em = emu(cols: 4)
      em.feed "abあ"                    # a@0 b@1, wide lead@2, continuation@3
      em.feed "\e[1;4H"                # cursor onto the trailing continuation half
      em.feed "い"                      # wide glyph: pre-wrap blank at col 3, glyph wraps
      emu_char(em, 2, 0).should eq ' ' # lead blanked, not left bare
      emu_char(em, 3, 0).should eq ' '
      emu_row(em, 0).should eq "ab"
      emu_char(em, 0, 1).should eq 'い' # wrapped onto the next row
    end
  end
end
