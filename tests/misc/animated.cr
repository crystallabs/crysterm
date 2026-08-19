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

# One shared clock: every widget given `animate: clock` advances one frame
# per tick, in lockstep. The tick period is sized so the throbber's full
# cycle is exactly the 5 s capture (one cycle per loop): the wrap lands on
# the same frame it started from, whatever the recording's start phase.
# The GIF's native 130 ms cadence would make a 4.42 s cycle — a visible
# 0.58 s frame-jump at every loop seam.
frame_count = PNGGIF::PNG.new(img).frames.try(&.size) || 1
clock = Timer.new (5.0 / frame_count).seconds

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Animated GIF · auto-picked (--media-backend=auto) · four backends in lockstep{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

half = s.awidth // 2
row_h = (s.aheight - 2) // 2

# The kitty panel soft-falls back on terminals without the protocol (pinning
# it there would print the raw APC payload as text); quadrant glyphs keep the
# four panels distinct. Captures always keep kitty (composited in-process).
kitty = Widget::Media.type_or_fallback(Widget::Media::Type::Kitty, Widget::Media::Type::GlyphQuadrant)

[
  {kitty, kitty.kitty? ? " --media-backend=kitty " : " glyph_quadrant · kitty n/a "},
  {Widget::Media::Type::GlyphOctant, " --media-backend=glyph_octant "},
  {Widget::Media::Type::GlyphSextant, " --media-backend=glyph_sextant "},
  {Widget::Media::Type::GlyphBraille, " --media-backend=glyph_braille "},
].each_with_index do |(type, label), i|
  Widget::Media.new \
    parent: s, type: type, file: img, fit: Widget::Media::Fit::Contain,
    animate: clock,
    top: 1 + (i // 2) * row_h, left: (i % 2) * half, width: half, height: row_h,
    label: label,
    style: Style.new(border: true)
end

Widget::Box.new \
  parent: s, top: s.aheight - 1, left: 0, width: "100%", height: 1,
  content: "{center}netscape.gif · one shared frame clock keeps all four panels in sync{/center}",
  parse_tags: true, style: Style.new(fg: "#8090a0")

s.exec
