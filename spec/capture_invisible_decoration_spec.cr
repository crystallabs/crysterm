require "./spec_helper"

include Crysterm

# `Capture.draw_cell` paints the glyph and the line decorations (underline,
# strikethrough) in the cell's foreground color. INVISIBLE (SGR 8, "conceal")
# hides the cell's foreground content — the glyph was already gated on it, but
# the decorations were not, so a concealed cell still leaked its text's presence
# and width through a drawn underline/strike. All foreground marks must share
# the guard. Driven headlessly over in-memory IOs.
private def cap_screen
  Crysterm::Window.new(input: IO::Memory.new, output: IO::Memory.new,
    error: IO::Memory.new, width: 2, height: 1)
end

private def fg_pixels(bmp, r, g, b)
  n = 0
  bmp.each do |row|
    row.each { |px| n += 1 if px.r == r && px.g == g && px.b == b }
  end
  n
end

describe "Capture INVISIBLE decorations" do
  fg = 0xffffff
  fr = (fg >> 16) & 0xff
  fgc = (fg >> 8) & 0xff
  fb = fg & 0xff

  it "draws no foreground pixels for a concealed underlined cell" do
    s = cap_screen
    s.alloc
    s.lines[0][0].attr = Attr.pack(Attr::INVISIBLE | Attr::UNDERLINE,
      Attr.pack_color(fg), Attr.pack_color(0x000000))
    s.lines[0][0].char = 'A'
    bmp = Crysterm::Capture.render(s, 0, 1, 0, 1)
    fg_pixels(bmp, fr, fgc, fb).should eq 0
  end

  it "draws no foreground pixels for a concealed struck-through cell" do
    s = cap_screen
    s.alloc
    s.lines[0][0].attr = Attr.pack(Attr::INVISIBLE | Attr::STRIKE,
      Attr.pack_color(fg), Attr.pack_color(0x000000))
    s.lines[0][0].char = 'A'
    bmp = Crysterm::Capture.render(s, 0, 1, 0, 1)
    fg_pixels(bmp, fr, fgc, fb).should eq 0
  end

  it "still draws the underline for a VISIBLE cell (no regression)" do
    s = cap_screen
    s.alloc
    s.lines[0][0].attr = Attr.pack(Attr::UNDERLINE,
      Attr.pack_color(fg), Attr.pack_color(0x000000))
    s.lines[0][0].char = ' ' # space: only the underline contributes fg pixels
    bmp = Crysterm::Capture.render(s, 0, 1, 0, 1)
    fg_pixels(bmp, fr, fgc, fb).should be > 0
  end
end
