# Media::Unicode::Quadrant — Matterhorn rendered via the Unicode::Quadrant backend.
# Fixed variant of Media::Glyph (see sibling dirs for the rest).
require "../../../../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Media::Unicode::Quadrant"

CW::MediaUnicodeQuadrant.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../../data/image/matterhorn.png"

CW::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Unicode::Quadrant  ·  Quadrant 2x2 · 2 colors/cell{/center}", parse_tags: true,
  style: CT::Style.new(fg: "white", bg: "#202830")

s.update
s.exec
