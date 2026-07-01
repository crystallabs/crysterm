# Media::Glyph::Quadrant — Matterhorn rendered via the Glyph::Quadrant backend.
# Fixed variant of Media::Glyph (see sibling dirs for the rest).
require "../../../../../src/crysterm"

include Crysterm

s = Window.new title: "Media::Glyph::Quadrant"

Widget::Media::Glyph::Quadrant.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Glyph::Quadrant  ·  Quadrant 2x2 · 2 colors/cell{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

s.render
s.exec
