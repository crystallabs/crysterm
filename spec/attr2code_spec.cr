require "./spec_helper"

include Crysterm

# Behavior lock for `Screen.attr2code` (SGR sequence -> packed Int64 attr).
# These pin the conversion across every SGR form so the allocation-free
# in-place parser can be verified to match the previous split-based one.
#
# `attr2code` is a pure class method (no screen state), so no Screen is needed.
describe "Screen.attr2code" do
  dfl = Crysterm::Screen::DEFAULT_ATTR # flags 0, default fg, default bg

  # Convenience: apply an SGR string starting from the default attr.
  apply = ->(code : String) { Crysterm::Screen.attr2code(code, dfl, dfl) }

  it "resets to default on \\e[0m and \\e[m (empty params)" do
    bolded = Crysterm::Screen.attr2code("\e[1m", dfl, dfl)
    (Attr.flags(bolded) & Attr::BOLD).should_not eq 0

    Crysterm::Screen.attr2code("\e[0m", bolded, dfl).should eq dfl
    Crysterm::Screen.attr2code("\e[m", bolded, dfl).should eq dfl # empty => 0 => reset
  end

  it "sets and clears individual style flags" do
    {
      "\e[1m" => Attr::BOLD,
      "\e[4m" => Attr::UNDERLINE,
      "\e[5m" => Attr::BLINK,
      "\e[7m" => Attr::REVERSE,
      "\e[8m" => Attr::INVISIBLE,
      "\e[9m" => Attr::STRIKE,
    }.each do |code, bit|
      a = apply.call(code)
      (Attr.flags(a) & bit).should_not eq 0
    end

    # 22/24/25/27/28 reset flags to the default's flags (0 here).
    bold = apply.call("\e[1m")
    Attr.flags(apply.call("\e[1m")).should_not eq 0
    Attr.flags(Crysterm::Screen.attr2code("\e[22m", bold, dfl)).should eq Attr.flags(dfl)
  end

  it "applies 8-color and bright (16-color) fg/bg" do
    # 31 = red fg ; palette index 1
    red_fg = apply.call("\e[31m")
    Attr.unpack_color(Attr.fg(red_fg)).should eq Colors.palette_to_rgb(1)

    # 41 = red bg
    red_bg = apply.call("\e[41m")
    Attr.unpack_color(Attr.bg(red_bg)).should eq Colors.palette_to_rgb(1)

    # 92 = bright green fg (palette 8+2=10)
    bgreen = apply.call("\e[92m")
    Attr.unpack_color(Attr.fg(bgreen)).should eq Colors.palette_to_rgb(10)

    # 100 = bright black bg (palette 8)
    bbg = apply.call("\e[100m")
    Attr.unpack_color(Attr.bg(bbg)).should eq Colors.palette_to_rgb(8)
  end

  it "applies 39/49 default fg/bg" do
    colored = apply.call("\e[31;41m")
    cleared_fg = Crysterm::Screen.attr2code("\e[39m", colored, dfl)
    Attr.unpack_color(Attr.fg(cleared_fg)).should eq -1
    cleared_bg = Crysterm::Screen.attr2code("\e[49m", colored, dfl)
    Attr.unpack_color(Attr.bg(cleared_bg)).should eq -1
  end

  it "applies 256-color (38;5;n / 48;5;n)" do
    fg = apply.call("\e[38;5;208m")
    Attr.unpack_color(Attr.fg(fg)).should eq Colors.palette_to_rgb(208)
    bg = apply.call("\e[48;5;21m")
    Attr.unpack_color(Attr.bg(bg)).should eq Colors.palette_to_rgb(21)
  end

  it "applies truecolor (38;2;r;g;b / 48;2;r;g;b)" do
    fg = apply.call("\e[38;2;255;136;0m")
    Attr.unpack_color(Attr.fg(fg)).should eq 0xff8800
    bg = apply.call("\e[48;2;16;32;48m")
    Attr.unpack_color(Attr.bg(bg)).should eq 0x102030
  end

  it "applies several codes in one sequence, in order" do
    a = apply.call("\e[1;31;48;2;16;32;48m")
    (Attr.flags(a) & Attr::BOLD).should_not eq 0
    Attr.unpack_color(Attr.fg(a)).should eq Colors.palette_to_rgb(1) # red
    Attr.unpack_color(Attr.bg(a)).should eq 0x102030                 # truecolor bg
  end

  it "carries over the current attr when codes don't touch a field" do
    base = apply.call("\e[31m")                        # red fg
    a = Crysterm::Screen.attr2code("\e[1m", base, dfl) # add bold, keep red fg
    (Attr.flags(a) & Attr::BOLD).should_not eq 0
    Attr.unpack_color(Attr.fg(a)).should eq Colors.palette_to_rgb(1)
  end
end
