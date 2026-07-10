require "./spec_helper"

include Crysterm

# Regression specs for BUGS13 findings A1, A2 and A5 — negative absolute
# coordinates wrapping into the far end of the screen buffer (Indexable#[]?
# accepts negative indices).
#
#  A1 (src/widget/box.cr): `Box#draw_text_run` had no `y < 0` / `cx < 0` guard,
#     so a widget partly off the top/left edge stamped its text overlay onto the
#     bottom/right of the terminal.
#
#  A2 (src/widget/bigtext.cr): `BigText#render` guarded negative columns but not
#     negative rows — `lines[y]?` with `y = top < 0` wrapped to the bottom of
#     the screen. Its column guard also compared against a possibly-negative
#     `left`, admitting negative columns.
#
#  A5 (src/widget/color_dialog.cr): the gradient field / hue bar overlays were
#     painted at raw absolute coords with no clip or negative guard, wrapping
#     cells when the dialog is partially offscreen.

private def neg_screen(w = 40, h = 12)
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: w, height: h, default_quit_keys: false)
end

# Exposes the protected shared text-overlay primitive for direct testing.
private class SpecTextRunBox < Crysterm::Widget::Box
  def spec_run(y, x, text, xl, attr = nil)
    draw_text_run y, x, text, xl, attr
  end
end

describe "BUGS13 A1: Box#draw_text_run guards negative coordinates" do
  it "drops a negative row instead of wrapping to the bottom screen row" do
    s = neg_screen
    box = SpecTextRunBox.new parent: s, top: 0, left: 0, width: 20, height: 3
    s._render

    box.spec_run(-1, 5, "ZZZ", 20)

    # Before the fix, `lines[-1]` wrapped to the last screen row.
    (5..7).each do |x|
      s.lines[s.aheight - 1][x].char.should eq ' '
    end
  end

  it "skips negative columns instead of wrapping to the right end of the row" do
    s = neg_screen
    box = SpecTextRunBox.new parent: s, top: 0, left: 0, width: 20, height: 3
    s._render

    box.spec_run(1, -2, "ABC", 20)

    # Only the in-bounds tail is written...
    s.lines[1][0].char.should eq 'C'
    # ...and nothing wrapped to the far right of the row (cols width-2/width-1).
    s.lines[1][s.awidth - 2].char.should eq ' '
    s.lines[1][s.awidth - 1].char.should eq ' '
  end
end

describe "BUGS13 A2: BigText clips rows/columns hanging off the top/left edge" do
  it "does not wrap glyph rows to the bottom of the screen for a negative top" do
    s = neg_screen 60, 24
    bt = Crysterm::Widget::BigText.new parent: s, top: -6, left: 0,
      content: "A", style: Style.new(foreground_char: '#')
    s._render

    # The glyph is drawn with '#'; the rows that hang off the top must be
    # dropped, not painted onto the bottom rows of the screen.
    ratio_h = bt.ratio.height
    ratio_h.should be > 6 # the glyph really does hang off the top
    (s.aheight - 6...s.aheight).each do |y|
      s.awidth.times do |x|
        s.lines[y][x].char.should eq ' '
      end
    end
  end

  it "does not wrap glyph columns to the right of the screen for a negative left" do
    s = neg_screen 60, 24
    Crysterm::Widget::BigText.new parent: s, top: 0, left: -4,
      content: "A", style: Style.new(foreground_char: '#')
    s._render

    # Columns hanging off the left edge must be dropped, not wrapped to the
    # right end of the rows.
    (s.awidth - 4...s.awidth).each do |x|
      s.aheight.times do |y|
        s.lines[y][x].char.should eq ' '
      end
    end
  end
end

describe "BUGS13 A5: ColorDialog overlays are clipped to the rendered area" do
  it "does not wrap field/hue cells when the dialog is partially off the left edge" do
    s = neg_screen 80, 24
    cd = Crysterm::Widget::ColorDialog.new(
      parent: s, top: 0, left: -6, width: 56, height: 20)
    cd.show
    s._render

    # An untouched baseline cell (bottom-right corner is outside the dialog).
    base_attr = s.lines[23][79].attr

    # Before the fix, the gradient-field columns at x in -6..-1 wrapped to the
    # far right of their rows (cols 74..79), stamping colored attrs there.
    (0...20).each do |y|
      (74...80).each do |x|
        s.lines[y][x].attr.should eq base_attr
      end
    end
  end

  it "does not wrap field/hue rows when the dialog is partially off the top edge" do
    s = neg_screen 80, 24
    cd = Crysterm::Widget::ColorDialog.new(
      parent: s, top: -5, left: 0, width: 56, height: 20)
    cd.show
    s._render

    base_attr = s.lines[23][79].attr

    # Before the fix, field rows at y in -5..-1 wrapped to the bottom rows.
    (19...24).each do |y|
      (0...56).each do |x|
        s.lines[y][x].attr.should eq base_attr
      end
    end
  end
end
