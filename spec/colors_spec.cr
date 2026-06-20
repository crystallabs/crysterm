require "./spec_helper"

include Crysterm

# Specs for the TrueColor-native color model: `Colors` (parsing, mixing, and
# colorspace-aware SGR output) and `Attr` (Int64 fg/bg/flags packing).
describe Crysterm::Colors do
  describe ".convert" do
    it "parses hex strings into 24-bit RGB ints" do
      Colors.convert("#ff8800").should eq 0xff8800
      Colors.convert("#fff").should eq 0xffffff # short form expands
    end

    it "parses color names into their RGB value" do
      Colors.convert("red").should eq 0xcd0000
      Colors.convert("default").should eq -1
    end

    it "passes through native ints and packs rgb tuples/arrays" do
      Colors.convert(0x123456).should eq 0x123456
      Colors.convert(-1).should eq -1
      Colors.convert({16, 32, 48}).should eq 0x102030
      Colors.convert([255, 0, 255]).should eq 0xff00ff
    end
  end

  describe ".sgr_color" do
    it "emits TrueColor sequences when the terminal supports 16M colors" do
      Colors.sgr_color(0xff8800, true, 0x1000000).should eq "38;2;255;136;0"
      Colors.sgr_color(0x102030, false, 0x1000000).should eq "48;2;16;32;48"
    end

    it "reduces to the 256-color palette" do
      Colors.sgr_color(0xff8800, true, 256).should eq "38;5;208"
    end

    it "reduces to 16/8-color ANSI codes" do
      Colors.sgr_color(0xcd0000, true, 16).should eq "31"  # red fg
      Colors.sgr_color(0xcd0000, false, 16).should eq "41" # red bg
    end

    it "emits the default color code for -1" do
      Colors.sgr_color(-1, true, 0x1000000).should eq "39"
      Colors.sgr_color(-1, false, 256).should eq "49"
    end
  end

  describe ".mix" do
    it "mixes two RGB colors in RGB space" do
      Colors.mix(0x000000, 0xffffff, 0.5).should eq 0x7f7f7f
      Colors.mix(0xff0000, 0x0000ff, 0.5).should eq 0x7f007f
      Colors.mix(0x102030, 0x102030, 0.5).should eq 0x102030
    end
  end

  describe ".blend" do
    it "alpha-composites the fg and bg of two attrs" do
      a = Attr.pack(0, Attr.pack_color(0x000000), Attr.pack_color(0x000000))
      b = Attr.pack(0, Attr.pack_color(0xffffff), Attr.pack_color(0xffffff))
      blended = Colors.blend(a, b, 0.5)
      Attr.unpack_color(Attr.fg(blended)).should eq 0x7f7f7f
      Attr.unpack_color(Attr.bg(blended)).should eq 0x7f7f7f
    end

    it "leaves a default color untouched when there is nothing to mix it with" do
      a = Attr.pack(0, Attr::COLOR_DEFAULT, Attr.pack_color(0x808080))
      blended = Colors.blend(a, nil, 0.5)
      Attr.unpack_color(Attr.fg(blended)).should eq -1       # default stays default
      Attr.unpack_color(Attr.bg(blended)).should eq 0x404040 # darkened toward black
    end
  end
end

describe Crysterm::Attr do
  it "round-trips fg, bg and flags through pack/unpack" do
    a = Attr.pack(Attr::BOLD | Attr::UNDERLINE, Attr.pack_color(0xff8800), Attr.pack_color(0x102030))

    Attr.unpack_color(Attr.fg(a)).should eq 0xff8800
    Attr.unpack_color(Attr.bg(a)).should eq 0x102030
    (Attr.flags(a) & Attr::BOLD).should_not eq 0
    (Attr.flags(a) & Attr::UNDERLINE).should_not eq 0
    (Attr.flags(a) & Attr::BLINK).should eq 0
  end

  it "represents the terminal default color with a sentinel" do
    field = Attr.pack_color(-1)
    Attr.default?(field).should be_true
    Attr.unpack_color(field).should eq -1
  end

  it "keeps full 24-bit precision (white does not collide with the default sentinel)" do
    a = Attr.pack(0, Attr.pack_color(0xffffff), Attr.pack_color(0xffffff))
    Attr.unpack_color(Attr.fg(a)).should eq 0xffffff
    Attr.unpack_color(Attr.bg(a)).should eq 0xffffff
    Attr.default?(Attr.fg(a)).should be_false
  end
end
