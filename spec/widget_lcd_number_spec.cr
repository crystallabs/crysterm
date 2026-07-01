require "./spec_helper"

include Crysterm

private def lcd_mem_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Behavioral specs for `Widget::LCDNumber` — the seven-segment display had no
# coverage. The interesting logic is `#display`'s per-mode integer formatting
# (dec/hex/oct/bin), the string form, and the three-row segment rendering
# (right-alignment within `digit_count`, unknown chars → blank, one-cell gaps).
describe Crysterm::Widget::LCDNumber do
  it "formats an integer per its mode into #text" do
    s = lcd_mem_screen
    Crysterm::Widget::LCDNumber.new(parent: s).tap(&.display(42)).text.should eq "42"

    hex = Crysterm::Widget::LCDNumber.new parent: s, mode: Crysterm::Widget::LCDNumber::Mode::Hex
    hex.display 255
    hex.text.should eq "FF" # upper-cased hex

    oct = Crysterm::Widget::LCDNumber.new parent: s, mode: Crysterm::Widget::LCDNumber::Mode::Oct
    oct.display 8
    oct.text.should eq "10"

    bin = Crysterm::Widget::LCDNumber.new parent: s, mode: Crysterm::Widget::LCDNumber::Mode::Bin
    bin.display 5
    bin.text.should eq "101"
  end

  it "shows floats and literal strings as-is" do
    s = lcd_mem_screen
    lcd = Crysterm::Widget::LCDNumber.new parent: s
    lcd.display 3.5
    lcd.text.should eq "3.5"
    lcd.display "12:30"
    lcd.text.should eq "12:30"
  end

  it "accepts an initial value through the constructor" do
    s = lcd_mem_screen
    Crysterm::Widget::LCDNumber.new(1234, parent: s).text.should eq "1234"
    Crysterm::Widget::LCDNumber.new("A", parent: s).text.should eq "A"
  end

  it "renders three rows, right-aligned within digit_count" do
    s = lcd_mem_screen
    lcd = Crysterm::Widget::LCDNumber.new parent: s, digit_count: 3
    lcd.display 1
    rows = lcd.content.split('\n')
    rows.size.should eq 3
    # "1" is right-justified to width 3 => two leading blank glyphs then '1'.
    # Each glyph is 3 cells with a one-cell gap between glyphs (3*3 + 2 = 11).
    rows.each(&.size.should(eq(11)))
    # The '1' glyph's middle/bottom rows put the bar in the right-most column.
    seg1 = Crysterm::Widget::LCDNumber::SEGMENTS['1']
    rows[1].ends_with?(seg1[1]).should be_true
    rows[2].ends_with?(seg1[2]).should be_true
  end

  it "renders unknown characters as blank glyphs" do
    s = lcd_mem_screen
    lcd = Crysterm::Widget::LCDNumber.new parent: s, digit_count: 1
    lcd.display "?"
    # '?' has no SEGMENTS entry → EMPTY (all spaces), one 3-wide glyph, no gap.
    lcd.content.split('\n').should eq ["   ", "   ", "   "]
  end
end
