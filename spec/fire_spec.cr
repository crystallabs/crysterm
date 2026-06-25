require "./spec_helper"

include Crysterm

# `Widget::Effect::Fire` paints its interior directly into the cell buffer as
# packed `Int64` attrs (no tagged-content round-trip). Its simulation
# (`#resize`/`#advance`/`#cell`) is exercised directly, headlessly, with no
# animation fiber and no real terminal.

private def fire_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe Crysterm::Widget::Effect::Fire do
  it "lights the bottom and lets the flame fade to dark near the top" do
    s = fire_screen
    f = Crysterm::Widget::Effect::Fire.new parent: s, width: 16, height: 40
    f.resize 16, 40
    f.advance 16, 40

    # Bottom row is lit (a non-blank ramp glyph with a real color).
    bottom_ch, bottom_color = f.cell(0, 39, 16, 40)
    bottom_ch.should_not eq ' '
    bottom_color.should_not eq -1

    # Far enough above the source the flame has decayed to nothing.
    f.cell(0, 0, 16, 40).should eq({' ', -1})
  end

  it "burns a band of lit rows above the source" do
    s = fire_screen
    f = Crysterm::Widget::Effect::Fire.new parent: s, width: 16, height: 40
    f.resize 16, 40
    f.advance 16, 40

    # The flame reaches well above the bottom two rows.
    lit = (10...38).any? { |y| (0...16).any? { |x| f.cell(x, y, 16, 40)[1] != -1 } }
    lit.should be_true
  end

  it "renders an unsimulated cell as blank with the default fg" do
    s = fire_screen
    f = Crysterm::Widget::Effect::Fire.new parent: s, width: 4, height: 4
    f.resize 4, 4

    f.cell(0, 0, 4, 4).should eq({' ', -1}) # heat 0 -> blank
  end

  it "honors a custom integer color override" do
    s = fire_screen
    f = Crysterm::Widget::Effect::Fire.new parent: s, width: 8, height: 4,
      color: ->(_heat : Float64) { 0x123456 }
    f.resize 8, 4
    f.advance 8, 4

    f.cell(0, 3, 8, 4)[1].should eq 0x123456
  end
end
