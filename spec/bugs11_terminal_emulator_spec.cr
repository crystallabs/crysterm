require "./spec_helper"

include Crysterm

# Regression specs for BUGS11 findings #10 and #11 (src/terminal/emulator.cr).
# The emulator is pure (depends only on Attr), so it is exercised directly with
# no Window/PTY — matching spec/terminal_emulator_spec.cr.

describe Crysterm::TerminalEmulator do
  describe "malformed UTF-8 decoding (#10)" do
    # A real VT substitutes U+FFFD for invalid sequences rather than
    # materializing an invalid Char that re-serializes as invalid UTF-8.
    it "substitutes U+FFFD for a UTF-16 surrogate (ED A0 80)" do
      em = emu
      em.feed Bytes[0xED, 0xA0, 0x80]
      emu_char(em, 0, 0).should eq '�'
      emu_char(em, 0, 0).to_s.valid_encoding?.should be_true
    end

    it "substitutes U+FFFD for an out-of-range codepoint (F7 BF BF BF)" do
      em = emu
      em.feed Bytes[0xF7, 0xBF, 0xBF, 0xBF]
      emu_char(em, 0, 0).should eq '�'
      emu_char(em, 0, 0).to_s.valid_encoding?.should be_true
    end

    it "substitutes U+FFFD for a >= 0xF8 lead byte (F8 88 80 80 80)" do
      em = emu
      em.feed Bytes[0xF8, 0x88, 0x80, 0x80, 0x80]
      emu_char(em, 0, 0).should eq '�'
      emu_char(em, 0, 0).to_s.valid_encoding?.should be_true
    end

    it "substitutes U+FFFD for an overlong encoding (C1 81) instead of 'A'" do
      em = emu
      em.feed Bytes[0xC1, 0x81]
      emu_char(em, 0, 0).should_not eq 'A'
      emu_char(em, 0, 0).should eq '�'
      emu_char(em, 0, 0).to_s.valid_encoding?.should be_true
    end

    it "still decodes valid multibyte UTF-8 (é, U+20AC, U+1F600)" do
      em = emu
      em.feed "é€\u{1F600}"
      emu_char(em, 0, 0).should eq 'é'
      emu_char(em, 1, 0).should eq '€'
      emu_char(em, 2, 0).should eq '\u{1F600}'
    end
  end

  describe "OSC payload bound (#11)" do
    it "keeps @osc_buf bounded for an unterminated (BEL/ST-free) OSC" do
      em = emu
      em.feed "\e]0;"       # begin OSC 0 (set title)
      em.feed("x" * 10_000) # long BEL-free run
      em.osc_buffer_size.should be <= Crysterm::TerminalEmulator::OSC_MAX
    end

    it "still parses a normal title within the cap" do
      got = nil
      em = emu
      em.on_title = ->(t : String) { got = t; nil }
      em.feed "\e]0;hi\a"
      got.should eq "hi"
    end
  end
end
