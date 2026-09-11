# Media::Unicode::Braille — Matterhorn rendered via the Unicode::Braille backend.
# Fixed variant of Media::Glyph (see sibling dirs for the rest).
require "../../../../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Media::Unicode::Braille"

CW::MediaUnicodeBraille.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../../data/image/matterhorn.png"

CW::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Unicode::Braille  ·  Braille 2x4 dots · 1 color/cell{/center}", parse_tags: true,
  style: CT::Style.new(fg: "white", bg: "#202830")

s.update
s.exec
