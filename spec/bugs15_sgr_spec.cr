require "./spec_helper"

include Crysterm

# BUGS15 findings #39, #50, #51.
#
#   #39 — `Screen.attr2code` must parse colon-form (ISO 8613-6 / ITU T.416) SGR
#         sub-parameters (`38:5:n`, `38:2:r:g:b`, and the full `38:2::r:g:b`
#         colon form with an empty colorspace-id) identically to the `;` form,
#         and degrade an unknown colon param (`4:3`) to its base code rather than
#         dropping the whole SGR.
#   #50 — `decode_ansi` must accept the same colon-form extended-colour selectors
#         instead of rasterizing the tail as literal CP437 text.
#   #51 — `decode_ansi` must brighten the *default* foreground under SGR 1 (bold)
#         to bright white (15), not leave it light gray (7).
describe "BUGS15 colon-form SGR (#39/#50)" do
  dfl = Crysterm::Window::DEFAULT_ATTR
  apply = ->(code : String) { Crysterm::Screen.attr2code(code, dfl, dfl) }

  it "#39 parses colon-form 256-color (38:5:n) like the semicolon form" do
    fg = apply.call("\e[38:5:196m")
    Attr.unpack_color(Attr.fg(fg)).should eq Colors.palette_to_rgb(196)
    fg.should eq apply.call("\e[38;5;196m")

    bg = apply.call("\e[48:5:21m")
    Attr.unpack_color(Attr.bg(bg)).should eq Colors.palette_to_rgb(21)
  end

  it "#39 parses colon-form truecolor (38:2:r:g:b) like the semicolon form" do
    fg = apply.call("\e[38:2:255:136:0m")
    Attr.unpack_color(Attr.fg(fg)).should eq 0xff8800
    fg.should eq apply.call("\e[38;2;255;136;0m")
  end

  it "#39 handles the full ITU form with an empty colorspace-id (38:2::r:g:b)" do
    fg = apply.call("\e[38:2::255:136:0m")
    Attr.unpack_color(Attr.fg(fg)).should eq 0xff8800

    bg = apply.call("\e[48:2::16:32:48m")
    Attr.unpack_color(Attr.bg(bg)).should eq 0x102030
  end

  it "#39 handles a non-empty colorspace-id field (38:2:<cs>:r:g:b)" do
    # A 6-field colon form with a numeric colorspace id must skip that id too.
    fg = apply.call("\e[38:2:0:255:136:0m")
    Attr.unpack_color(Attr.fg(fg)).should eq 0xff8800
  end

  it "#39 degrades an unknown colon param (4:3 curly underline) to its base code" do
    # `\e[4:3m` must still apply underline (base param 4), not drop the whole SGR.
    a = apply.call("\e[4:3m")
    (Attr.flags(a) & Attr::UNDERLINE).should_not eq 0

    # Sub-params must be skipped up to the next ';', so a following param applies.
    b = apply.call("\e[4:3;31m")
    (Attr.flags(b) & Attr::UNDERLINE).should_not eq 0
    Attr.unpack_color(Attr.fg(b)).should eq Colors.palette_to_rgb(1) # red
  end
end

private def png(s : String)
  Crysterm::Widget::Media.decode_ansi(s.to_slice)
end

describe "BUGS15 decode_ansi colon SGR + bold default (#50/#51)" do
  it "#50 does not rasterize a colon-form selector's tail as literal text" do
    # Old bug: the scan stopped at ':' and `5:196mX` was painted as CP437 glyphs,
    # widening the grid. It must decode to a single colored 'X'.
    png("\e[38:5:196mX").width.should eq png("X").width
  end

  it "#50 maps a colon-form 256-color background (48:5:n)" do
    px = png("\e[48:5:9m ").bmp[0][0] # index 9 = bright red 0xFF5555
    {px.r, px.g, px.b}.should eq({0xFF, 0x55, 0x55})
  end

  it "#50 maps a colon-form truecolor background (48:2:r:g:b)" do
    px = png("\e[48:2:255:0:0m ").bmp[0][0] # pure red -> nearest index 1 (0xAA0000)
    {px.r, px.g, px.b}.should eq({0xAA, 0x00, 0x00})
  end

  it "#50 maps the full ITU colon form with empty colorspace-id (48:2::r:g:b)" do
    # The empty colorspace field must not be misread as the red channel.
    px = png("\e[48:2::255:0:0m ").bmp[0][0]
    {px.r, px.g, px.b}.should eq({0xAA, 0x00, 0x00})
  end

  it "#51 renders bold default foreground as bright white, not gray" do
    # Reverse video surfaces the foreground on a blank cell. `\e[1m` (bold) with
    # no explicit color must yield bright white (index 15, 0xFFFFFF).
    px = png("\e[1m\e[7m ").bmp[0][0]
    {px.r, px.g, px.b}.should eq({0xFF, 0xFF, 0xFF})
  end

  it "#51 leaves the non-bold default foreground light gray" do
    px = png("\e[7m ").bmp[0][0] # default fg = index 7 (0xAAAAAA)
    {px.r, px.g, px.b}.should eq({0xAA, 0xAA, 0xAA})
  end
end
