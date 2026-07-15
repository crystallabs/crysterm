require "./spec_helper"

include Crysterm

# `Widget::Dial#pointer` maps the current value onto one of eight compass
# glyphs. The old mapping used `frac * POINTERS.size` unconditionally, correct
# only for a *wrapping* dial (max rolls back onto min's "north"). For a
# non-wrapping dial this was a bug: `frac == 1.0` rounded to `size` and wrapped
# (`% size`) back to index 0, so the maximum showed `↑` same as the minimum,
# and an in-between direction could be skipped. Fix: non-wrapping dials spread
# the range across the arc (`frac * (size - 1)`) so the ends differ.
#
# Driven headlessly: the dial paints its pointer glyph into the center cell of
# its interior, read back after one render.

private def dp_screen
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# Pointer glyph at the center of the dial's interior, computed the same way as
# `Dial#render` (`with_inner_coords` insets), so it's correct with a themed
# border/padding too.
private def center_glyph(s, dial) : Char
  s._render
  cx = dial.aleft + dial.ileft + ((dial.awidth - dial.ihorizontal) // 2)
  cy = dial.atop + dial.itop + ((dial.aheight - dial.ivertical) // 2)
  s.lines[cy][cx].char
end

describe "Widget::Dial#pointer" do
  it "points the maximum of a non-wrapping dial in a different direction than the minimum" do
    s = dp_screen
    dial = Crysterm::Widget::Dial.new parent: s, top: 0, left: 0, width: 9, height: 3,
      minimum: 0, maximum: 7, value: 0, show_value: false, wrapping: false

    at_min = center_glyph(s, dial)
    at_min.should eq '↑' # north at the minimum

    dial.value = 7 # the maximum
    at_max = center_glyph(s, dial)
    at_max.should eq '↖'        # last compass glyph, not north
    at_max.should_not eq at_min # core of the bug: ends must differ
  end

  it "shows every direction across a non-wrapping 8-value range (no skipped glyph)" do
    s = dp_screen
    dial = Crysterm::Widget::Dial.new parent: s, top: 0, left: 0, width: 9, height: 3,
      minimum: 0, maximum: 7, value: 0, show_value: false, wrapping: false

    seen = (0..7).map do |v|
      dial.value = v
      center_glyph s, dial
    end

    # The eight values map one-to-one onto the eight compass glyphs.
    seen.should eq Crysterm::Widget::Dial::POINTERS
  end

  it "still rolls a wrapping dial's maximum back onto the minimum's north (full circle preserved)" do
    s = dp_screen
    dial = Crysterm::Widget::Dial.new parent: s, top: 0, left: 0, width: 9, height: 3,
      minimum: 0, maximum: 7, value: 0, show_value: false, wrapping: true

    dial.value = 7
    center_glyph(s, dial).should eq '↑'
  end
end
