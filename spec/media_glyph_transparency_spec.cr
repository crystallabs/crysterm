require "./spec_helper"

include Crysterm

# Regression spec: transparent sub-pixels must not bleed their (black) colour
# into a `Glyph` cell.
#
# The multi-column glyph modes (`Quadrant`/`Sextant`/`Octant`, via
# `paint_two_color`) and `Half` split a cell's sub-pixels into ink (fg) and
# paper (bg). Transparent pixels — a `Fit::Contain` letterbox margin or a hole
# in the source image — are stored as black `(0,0,0,0)`. They used to be
# averaged into the paper colour and the luminance threshold, painting a dark
# fringe along the image's edges and its first/last (letterbox) rows. The fix
# excludes any sub-pixel with alpha 0 from the colour/threshold computation,
# letting it affect only the cell's coverage (alpha).

private def render_cell(mode : Widget::Media::Glyph::Mode, bmp : PNGGIF::Bitmap)
  s = Window.new(input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 20, height: 6)
  # One cell => sample is exactly this mode's sub-grid; Stretch keeps it 1:1.
  img = Widget::Media::Glyph.new(parent: s, top: 0, left: 0, width: 1, height: 1,
    mode: mode, fit: Widget::Media::Fit::Stretch)
  img.bitmap = bmp
  s.repaint
  s.lines[0][0]
ensure
  s.try &.destroy
end

# A `w`×`h` bitmap: top half opaque `rgb`, bottom half transparent, tinted with
# `hole_rgb` (whose colour must be invisible once alpha is 0).
private def top_opaque(rgb : Int32, hole_rgb : Int32, w : Int32, h : Int32) : PNGGIF::Bitmap
  r = (rgb >> 16) & 0xff; g = (rgb >> 8) & 0xff; b = rgb & 0xff
  hr = (hole_rgb >> 16) & 0xff; hg = (hole_rgb >> 8) & 0xff; hb = hole_rgb & 0xff
  Array.new(h) do |y|
    Array.new(w) do
      y < h // 2 ? PNGGIF::Pixel.new(r, g, b, 255) : PNGGIF::Pixel.new(hr, hg, hb, 0)
    end
  end
end

describe "Widget::Media::Glyph transparency" do
  # Octant (2x4) and Half (1x2) both split a cell into fg/bg; both must ignore
  # the colour of transparent sub-pixels.
  {
    Widget::Media::Glyph::Mode::Octant   => {2, 4},
    Widget::Media::Glyph::Mode::Quadrant => {2, 2},
    Widget::Media::Glyph::Mode::Half     => {1, 2},
  }.each do |mode, (w, h)|
    it "ignores the colour of transparent sub-pixels in #{mode} mode" do
      white = 0xffffff
      # Same geometry/coverage, different colour hiding behind alpha 0.
      black_hole = render_cell(mode, top_opaque(white, 0x000000, w, h))
      red_hole = render_cell(mode, top_opaque(white, 0xff0000, w, h))

      # Transparent pixels contribute no colour, so the two renders are identical.
      red_hole.attr.should eq black_hole.attr
      red_hole.char.should eq black_hole.char
    end

    it "does not paint a black paper fringe from the transparent half in #{mode} mode" do
      cell = render_cell(mode, top_opaque(0xffffff, 0x000000, w, h))
      # Ink is white; with the bug the paper (bg) was pure black. After the fix
      # the paper borrows the ink colour, so — faded over the terminal's default
      # (black) background at partial coverage — the bg is a non-black grey.
      bg = Attr.unpack_color(Attr.bg(cell.attr))
      bg.should_not eq 0x000000
    end
  end
end
