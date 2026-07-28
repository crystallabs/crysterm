# FEATURE: animated images (GIF/APNG), synced across backends.
#
# Every image backend animates: an animated GIF or APNG plays automatically,
# each frame shown for its own source delay. Here the classic Netscape
# throbber plays simultaneously in four different backends — Kitty pixel
# graphics, then sub-cell glyph octants, sextants and braille — all driven
# from one shared frame clock (`animate: <Timer>`), so the four panels stay
# in exact lockstep.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Media: animation"

img = "#{__DIR__}/../../data/image/netscape.gif"

# One shared clock, ticking at the GIF's own frame delay: every widget given
# `animate: clock` advances one frame per tick, in lockstep.
delay = PNGGIF::PNG.new(img).frames.try(&.first?.try(&.delay)) || 100
clock = Timer.new delay.milliseconds

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Animated GIF · auto-picked (--media-backend=auto) · four backends in lockstep{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

half = s.awidth // 2
row_h = (s.aheight - 2) // 2

[
  {Widget::Media::Type::Kitty, "kitty"},
  {Widget::Media::Type::GlyphOctant, "glyph_octant"},
  {Widget::Media::Type::GlyphSextant, "glyph_sextant"},
  {Widget::Media::Type::GlyphBraille, "glyph_braille"},
].each_with_index do |(type, name), i|
  Widget::Media.new \
    parent: s, type: type, file: img, fit: Widget::Media::Fit::Contain,
    animate: clock,
    top: 1 + (i // 2) * row_h, left: (i % 2) * half, width: half, height: row_h,
    label: " --media-backend=#{name} ",
    style: Style.new(border: true)
end

Widget::Box.new \
  parent: s, top: s.aheight - 1, left: 0, width: "100%", height: 1,
  content: "{center}netscape.gif · one shared frame clock keeps all four panels in sync{/center}",
  parse_tags: true, style: Style.new(fg: "#8090a0")

s.exec
