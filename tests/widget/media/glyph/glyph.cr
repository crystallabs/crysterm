# Media::Glyph — the Matterhorn rendered with sub-cell mosaic glyphs, in the
# default mode. The sibling dirs pin one mode each
# (block / half / quadrant / sextant / octant / braille / ascii).
require "../../../../src/crysterm"

include Crysterm

s = Window.new title: "Media::Glyph"

Widget::Media::Glyph.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Glyph  ·  sub-cell glyphs · default mode{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

s.render
s.exec
