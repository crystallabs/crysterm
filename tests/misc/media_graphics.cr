# FEATURE: in-band terminal graphics (Sixel, Kitty, iTerm2, ReGIS).
#
# Beyond character cells, Crysterm can hand the terminal *real pixels*: an
# escape sequence embedded in the normal output stream that a capable
# terminal renders as an image — DEC Sixel, the Kitty graphics protocol,
# iTerm2 inline images, or DEC ReGIS vectors. Normally the best protocol the
# terminal supports is picked automatically (`--media-backend=auto`); each
# panel here forces one so all four can be compared on the same image.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Media: terminal graphics"

img = "#{__DIR__}/../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}In-band pixel graphics · auto-picked (--media-backend=auto) · forced per panel{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

half = s.awidth // 2
row_h = (s.aheight - 2) // 2

[
  {Widget::Media::Type::Sixel, "sixel"},
  {Widget::Media::Type::Kitty, "kitty"},
  {Widget::Media::Type::Iterm, "iterm"},
  {Widget::Media::Type::Regis, "regis"},
].each_with_index do |(type, name), i|
  Widget::Media.new \
    parent: s, type: type, file: img, fit: Widget::Media::Fit::Contain,
    top: 1 + (i // 2) * row_h, left: (i % 2) * half, width: half, height: row_h,
    label: " --media-backend=#{name} ",
    style: Style.new(border: true)
end

Widget::Box.new \
  parent: s, top: s.aheight - 1, left: 0, width: "100%", height: 1,
  content: "{center}real pixels, drawn by the terminal itself · needs a graphics-capable terminal{/center}",
  parse_tags: true, style: Style.new(fg: "#8090a0")

s.exec
