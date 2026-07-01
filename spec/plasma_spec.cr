require "./spec_helper"

include Crysterm

# `Plasma` paints directly into the cell buffer as packed `Int64` attrs. Its
# per-cell logic is pure given the frame counter, so `#cell`/`#advance` are
# exercised directly with no animation fiber or real terminal.

private def plasma_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe Crysterm::Widget::Effect::Plasma do
  it "returns the configured glyph and an in-range 0xRRGGBB color per cell" do
    s = plasma_screen
    p = Crysterm::Widget::Effect::Plasma.new parent: s, width: 20, height: 10, glyph: '#'

    ch, color = p.cell(3, 4, 20, 10)
    ch.should eq '#'
    (0..0xffffff).should contain color
  end

  it "is a pure function of position and frame (same frame -> same color)" do
    s = plasma_screen
    p = Crysterm::Widget::Effect::Plasma.new parent: s, width: 20, height: 10

    first = p.cell(5, 5, 20, 10)
    p.cell(2, 2, 20, 10) # other lookups must not mutate state
    p.cell(5, 5, 20, 10).should eq first
  end

  it "advances the field so a cell's color changes frame to frame" do
    s = plasma_screen
    p = Crysterm::Widget::Effect::Plasma.new parent: s, width: 20, height: 10

    before = p.cell(5, 5, 20, 10)[1]
    p.step # advance one frame (state only)
    p.cell(5, 5, 20, 10)[1].should_not eq before
  end
end
