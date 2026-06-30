# Media::Glyph::Sextant — the Matterhorn rendered via the Glyph::Sextant backend.
#
# A single fixed variant of Media::Glyph (see the sibling dirs for the rest).
require "../../../../../src/crysterm"

include Crysterm

s = Window.new title: "Media::Glyph::Sextant"

Widget::Media::Glyph::Sextant.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Glyph::Sextant  ·  Sextant 2x3 · 2 colors/cell{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

s.render
s.exec
