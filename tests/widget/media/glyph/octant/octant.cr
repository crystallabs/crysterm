# Media::Unicode::Octant — Matterhorn rendered via the Unicode::Octant backend.
# Fixed variant of Media::Glyph (see sibling dirs for the rest).
require "../../../../../src/crysterm"

include Crysterm
include Crysterm::Widgets

s = Window.new title: "Media::Unicode::Octant"

Media::Unicode::Octant.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Unicode::Octant  ·  Octant 2x4 · 2 colors/cell{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

s.render
s.exec
