# Media::Glyph::Braille — the Matterhorn rendered via the Glyph::Braille backend.
#
# A single fixed variant of Media::Glyph (see the sibling dirs for the rest).
require "../../../../../src/crysterm"

include Crysterm

s = Window.new title: "Media::Glyph::Braille"

Widget::Media::Glyph::Braille.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Glyph::Braille  ·  Braille 2x4 dots · 1 color/cell{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

s.render
s.exec
