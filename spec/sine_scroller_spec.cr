require "./spec_helper"

include Crysterm

# `Widget::Effect::SineScroller` scroll + wave logic, driven headlessly over
# in-memory IOs so no real terminal is touched. `#step` is pure (it only
# recomposes `content`; it does not render or sleep), so it can be exercised
# directly without the animation fiber.

private def sine_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe Crysterm::Widget::Effect::SineScroller do
  it "composes one line per row of its height" do
    s = sine_screen
    sc = Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 6, height: 5, text: "X", rainbow: false
    sc.step
    sc.content.split('\n').size.should eq sc.aheight
  end

  it "places a glyph on the row given by the sine wave" do
    s = sine_screen
    # height 5 -> amp = 2; flat wave (freq 0) so every column lands on the same row.
    sc = Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 1, height: 5, text: "X", rainbow: false,
      wave_frequency: 0.0, wave_speed: Math::PI / 2
    # f=0: sin(0)=0   -> row amp*(1+0)=2
    sc.step
    sc.content.split('\n').index("X").should eq 2
    # f=1: sin(pi/2)=1 -> row amp*(1+1)=4 (bottom)
    sc.step
    sc.content.split('\n').index("X").should eq 4
    # f=2: sin(pi)=0   -> back to row 2
    sc.step
    sc.content.split('\n').index("X").should eq 2
  end

  it "scrolls horizontally like a marquee when flat (height 1)" do
    s = sine_screen
    sc = Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 5, height: 1, text: "ABCDE", rainbow: false
    sc.step # f=0
    sc.content.should eq "ABCDE"
    sc.step # f=1 — shifted left by one column
    sc.content.should eq "BCDEA"
  end

  it "tints glyphs and leaves spaces blank under rainbow" do
    s = sine_screen
    sc = Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 4, height: 3, text: "A B"
    sc.step
    sc.content.should contain "-fg}"
    sc.content.should contain "{/}"
  end

  it "renders an all-blank frame for an all-space message" do
    s = sine_screen
    sc = Crysterm::Widget::Effect::SineScroller.new parent: s, top: 0, left: 0,
      width: 4, height: 3, text: "    "
    sc.step
    sc.content.should_not contain "-fg}"
    sc.content.gsub('\n', "").blank?.should be_true
  end
end
