require "./spec_helper"

include Crysterm

# `Widget::Dial#pointer` maps the current value onto one of eight compass
# glyphs. The old mapping used `frac * POINTERS.size` unconditionally, which is
# only correct for a *wrapping* dial: there the maximum is meant to roll back
# onto the minimum's "north". For the default *non-wrapping* dial it was a bug —
# `frac == 1.0` rounded to `size` and wrapped (`% size`) back to index 0, so the
# maximum showed `↑`, identical to the minimum, and an in-between direction could
# be skipped. A non-wrapping dial must spread the range across the arc
# (`frac * (size - 1)`) so the two ends point in distinct directions.
#
# Driven headlessly: the dial paints its pointer glyph into the center cell of
# its interior, which these specs read back after one render.

private def dp_screen
  Crysterm::Screen.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: 80,
    height: 24,
    default_quit_keys: false)
end

# The pointer glyph painted at the center of the dial's interior. The center is
# computed exactly as `Dial#render` does (`with_inner_coords` insets), so it is
# correct even if a theme gives the dial a border/padding.
private def center_glyph(s, dial) : Char
  s._render
  cx = dial.aleft + dial.ileft + ((dial.awidth - dial.iwidth) // 2)
  cy = dial.atop + dial.itop + ((dial.aheight - dial.iheight) // 2)
  s.lines[cy][cx].char
end

describe "Widget::Dial#pointer" do
  it "points the maximum of a non-wrapping dial in a different direction than the minimum" do
    s = dp_screen
    dial = Crysterm::Widget::Dial.new parent: s, top: 0, left: 0, width: 9, height: 3,
      minimum: 0, maximum: 7, value: 0, show_value: false, wrap: false

    at_min = center_glyph(s, dial)
    at_min.should eq '↑' # north at the minimum

    dial.value = 7 # the maximum
    at_max = center_glyph(s, dial)
    at_max.should eq '↖'        # the last compass glyph, distinctly *not* north
    at_max.should_not eq at_min # the core of the bug: ends must differ
  end

  it "shows every direction across a non-wrapping 8-value range (no skipped glyph)" do
    s = dp_screen
    dial = Crysterm::Widget::Dial.new parent: s, top: 0, left: 0, width: 9, height: 3,
      minimum: 0, maximum: 7, value: 0, show_value: false, wrap: false

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
      minimum: 0, maximum: 7, value: 0, show_value: false, wrap: true

    dial.value = 7
    center_glyph(s, dial).should eq '↑'
  end
end
