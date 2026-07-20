require "./spec_helper"

include Crysterm

# BUGS11 #19 — Right-aligned BigText with wide (CJK/emoji) glyphs painted left of
# the widget and, via negative `Row#[]?` indexing, wrapped glyph pixels to the far
# right of the screen row.
#
# `max_chars` counted glyphs in half-width cell units (`(right-left)//ratio.width`)
# but `advance` summed each glyph's real column count (2×ratio.width for full-width
# glyphs), so for right alignment `x = right - advance` could fall below `left` or
# go negative. `lines[y]?.try(&.[x + mx]?)` then wrapped negative indices to the
# end of the row, painting outside the widget / into other widgets.

private def bt_screen(w = 80, h = 24)
  Crysterm::Window.new(
    input: IO::Memory.new,
    output: IO::Memory.new,
    error: IO::Memory.new,
    width: w,
    height: h,
    default_quit_keys: false)
end

private def bt_cell_char(screen, y, x)
  screen.lines[y][x].char
end

describe "BUGS11 #19: right-aligned BigText with wide CJK glyphs stays in bounds" do
  it "never paints outside [left, right) — no negative/far-right wrapped cells" do
    screen_w = 80
    s = bt_screen screen_w, 24

    left = 0
    width = 20
    right = left + width # interior right edge (exclusive), no border

    # `foreground_char` makes lit glyph pixels observable as a visible char.
    Crysterm::Widget::BigText.new parent: s, top: 0, left: left, width: width,
      height: 16, align: :right,
      content: "漢字テスト",
      foreground_char: '#'

    s.repaint

    lit = [] of Tuple(Int32, Int32) # {y, x}
    (0...24).each do |y|
      (0...screen_w).each do |x|
        lit << {y, x} if bt_cell_char(s, y, x) == '#'
      end
    end

    # The bug painted glyph pixels; assert something was drawn so the test is
    # meaningful (a no-op render would trivially "pass" the bounds checks).
    lit.should_not be_empty

    # Every lit cell must fall within the widget's interior horizontal span.
    lit.each do |(_y, x)|
      x.should be >= left
      x.should be < right
    end

    # Specifically: nothing painted right of the widget's right edge, and nothing
    # in the far-right columns of the row (where negative indices used to wrap to).
    lit_cols = lit.map { |(_y, x)| x }
    lit_cols.max.should be < right
    lit_cols.min.should be >= left
    # The last columns of the screen row must be untouched.
    (right...screen_w).each do |x|
      (0...24).each do |y|
        bt_cell_char(s, y, x).should_not eq '#'
      end
    end
  end
end
