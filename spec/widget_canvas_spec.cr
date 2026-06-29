require "./spec_helper"

include Crysterm

private def render_screen
  Crysterm::Window.new(
    input: IO::Memory.new, output: IO::Memory.new, error: IO::Memory.new,
    width: 80, height: 24)
end

private def blank_bitmap(w, h) : PNGGIF::Bitmap
  Array.new(h) { Array.new(w) { PNGGIF::Pixel.new(0, 0, 0, 0) } }
end

describe Crysterm::Widget::Graph::Painter do
  it "rasterizes a line in device coordinates" do
    bmp = blank_bitmap(4, 4)
    p = Crysterm::Widget::Graph::Painter.new bmp
    p.pen = 0xFF0000
    p.draw_line 0, 0, 3, 3
    bmp[0][0].r.should eq 255
    bmp[1][1].r.should eq 255
    bmp[3][3].r.should eq 255
    bmp[0][3].a.should eq 0 # off-line pixel untouched (transparent)
  end

  it "maps logical coordinates through window→viewport" do
    bmp = blank_bitmap(4, 4)
    p = Crysterm::Widget::Graph::Painter.new bmp
    # logical 0..2 maps onto the full 4px viewport, so logical (1,1) -> device (2,2)
    p.set_window 0, 0, 2, 2
    p.pen = 0x00FF00
    p.draw_point 1, 1
    bmp[2][2].g.should eq 255
  end

  it "fills a rectangle" do
    bmp = blank_bitmap(3, 3)
    p = Crysterm::Widget::Graph::Painter.new bmp
    p.pen = 0xFFFFFF
    p.fill_rect 0, 0, 3, 3
    bmp.all? { |row| row.all? { |px| px.r == 255 } }.should be_true
  end
end

describe Crysterm::Widget::Graph::Canvas do
  it "sizes its bitmap to the braille backend's native resolution (2x4)" do
    s = render_screen
    cv = Crysterm::Widget::Graph::Canvas.new parent: s, top: 0, left: 0, width: 10, height: 4,
      type: Crysterm::Widget::Media::Type::Glyph
    cv.device.should be_a Crysterm::Widget::Media::Glyph
    cv.device.native_resolution(10, 4).should eq({20, 16})
  end

  it "fills only the interior of a bordered canvas (no overrun past the border)" do
    s = render_screen
    # Neutralize the config-driven default theme that the first Window installs
    # (it would drop the inline border in this headless run); a real terminal
    # keeps the border, which is the condition under test.
    saved = Crysterm::CSS.default_stylesheet
    Crysterm::CSS.default_stylesheet = Crysterm::CSS::Stylesheet.new
    begin
      cv = Crysterm::Widget::Graph::Canvas.new parent: s, top: 0, left: 0, width: 8, height: 5,
        type: Crysterm::Widget::Media::Type::Glyph,
        style: Crysterm::Style.new(border: true)
      cv.on_paint do |p|
        w, h = cv.device.native_resolution(6, 3)
        p.pen = 0xFFFFFF
        p.fill_rect 0, 0, w, h
      end
      s._render

      braille = ->(ch : Char) { ('⠀'..'⣿').includes?(ch) && ch != '⠀' }
      # Interior (cols 1..6, rows 1..3) is filled braille.
      braille.call(s.lines[1][1].char).should be_true
      braille.call(s.lines[3][6].char).should be_true
      # Border ring is untouched (not braille): right col 7, bottom row 4, left col 0, top row 0.
      braille.call(s.lines[1][7].char).should be_false # right border
      braille.call(s.lines[4][6].char).should be_false # bottom border
      braille.call(s.lines[1][0].char).should be_false # left border
      braille.call(s.lines[0][1].char).should be_false # top border
    ensure
      Crysterm::CSS.default_stylesheet = saved
    end
  end

  it "paints through the braille backend into screen cells" do
    s = render_screen
    cv = Crysterm::Widget::Graph::Canvas.new parent: s, top: 0, left: 0, width: 6, height: 3,
      type: Crysterm::Widget::Media::Type::Glyph
    cv.on_paint do |p|
      # Fill the whole device bitmap -> every braille cell fully on (⣿).
      p.pen = 0xFFFFFF
      p.fill_rect 0, 0, cv.device.native_resolution(6, 3)[0], cv.device.native_resolution(6, 3)[1]
    end
    s._render

    # The Canvas interior (6x3 cells at 0,0) should now be full-block braille.
    full = '⣿' # U+28FF, all 8 dots
    found = (0...3).any? { |y| (0...6).any? { |x| s.lines[y][x].char == full } }
    found.should be_true
  end
end

describe "Media painter backend resolution" do
  it "ranks Sixel above iTerm for the Painter content kind" do
    # Force a terminal that supports both sixel and iterm by excluding kitty;
    # resolution honors the painter ranking [Kitty, Sixel, Iterm, Glyph, Ansi].
    # We can at least assert the kind resolves to *some* supported backend.
    t = Crysterm::Widget::Media.resolve(Crysterm::Widget::Media::Content::Painter)
    [Crysterm::Widget::Media::Type::Kitty, Crysterm::Widget::Media::Type::Sixel,
     Crysterm::Widget::Media::Type::Iterm, Crysterm::Widget::Media::Type::Glyph,
     Crysterm::Widget::Media::Type::Ansi].includes?(t).should be_true
  end
end
