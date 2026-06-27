require "./spec_helper"

include Crysterm

# Regression: `Capture.draw_cell` used to clamp every cell's background fill and
# glyph to a single cell width (`cw`). A wide (2-column) grapheme such as a
# full-width CJK character is 16 px wide in the default Unifont, and its trailing
# continuation cell carries no cell of its own (`each_content_cell` skips it), so
# the right half of the glyph — and the wide cell's background over that column —
# was never painted, leaving a clipped half-glyph on a default-colored gap.
# Driven headlessly over in-memory IOs.

private def wide_screen
  Crysterm::Screen.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 4, height: 1)
end

describe "Capture wide-glyph rendering" do
  it "paints the right half of a 2-column glyph into the continuation column" do
    s = wide_screen
    line = s.lines[0]
    line[0].attr = Crysterm::Screen::DEFAULT_ATTR
    line[0].grapheme = "中" # full-width: occupies 2 columns
    line[1].continuation!

    line[0].width.should eq(2) # sanity: a wide cell

    cw = Crysterm::Font.default_normal.width # 8 for Unifont
    bmp = Crysterm::Capture.render(s, 0, 2, 0, 1)

    # Foreground color used for the terminal-default fg.
    fg = Crysterm::Capture::DEFAULT_FG
    fr = (fg >> 16) & 0xff
    fgi = (fg >> 8) & 0xff
    fb = fg & 0xff

    # The right half (columns [cw, 2*cw)) — i.e. the continuation column's
    # pixels — must contain at least one foreground (lit-glyph) pixel.
    lit_right = false
    bmp.each do |row|
      (cw...(2 * cw)).each do |x|
        px = row[x]
        lit_right = true if px.r == fr && px.g == fgi && px.b == fb
      end
    end
    lit_right.should be_true
  end
end
