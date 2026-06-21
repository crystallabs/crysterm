require "./spec_helper"

include Crysterm

# `Widget::Effect::Matrix` paints its interior directly into the cell buffer as
# packed `Int64` attrs (no tagged-content round-trip). Its per-column drop
# simulation (`#resize`/`#advance`/`#cell`) is exercised directly, headlessly,
# with no animation fiber and no real terminal. A single-char `pool` makes the
# sampled glyph deterministic so colors can be asserted.

private def matrix_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new)
end

describe Crysterm::Widget::Effect::Matrix do
  it "paints heads, fading green trails, and blanks elsewhere" do
    s = matrix_screen
    m = Crysterm::Widget::Effect::Matrix.new parent: s, width: 8, height: 8,
      pool: ['X'], head_color: "#ccffcc"
    m.resize 8, 8

    head_color = Crysterm::Colors.convert_cached("#ccffcc")
    seen_head = false
    seen_trail = false

    # Drops start above the top (negative offsets); run enough frames for heads
    # and trails to fall through the box.
    40.times do
      m.advance 8, 8
      (0...8).each do |y|
        (0...8).each do |x|
          ch, color = m.cell(x, y, 8, 8)
          if ch == ' '
            color.should eq -1 # blank keeps the default fg
          else
            ch.should eq 'X'
            if color == head_color
              seen_head = true
            else
              # Trail: r == 0x00, b == 0x22, green channel carries the fade.
              ((color >> 16) & 0xff).should eq 0x00
              (color & 0xff).should eq 0x22
              seen_trail = true
            end
          end
        end
      end
    end

    seen_head.should be_true
    seen_trail.should be_true
  end

  it "rebuilds per-column state on resize without raising" do
    s = matrix_screen
    m = Crysterm::Widget::Effect::Matrix.new parent: s, width: 8, height: 8, pool: ['X']
    m.resize 8, 8
    m.advance 8, 8
    m.resize 20, 5 # smaller height, wider — fresh columns
    m.advance 20, 5
    m.cell(19, 4, 20, 5) # last cell of the new geometry must be addressable
  end
end
