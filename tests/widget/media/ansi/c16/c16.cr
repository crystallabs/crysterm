# Media::Ansi::C16 — Matterhorn rendered via the Ansi::C16 backend.
# Fixed variant of Media::Ansi (see sibling dirs for the rest).
require "../../../../../src/crysterm"

include Crysterm

s = Window.new title: "Media::Ansi::C16"

Widget::Media::Ansi::C16.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Ansi::C16  ·  16-color · ANSI palette{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

s.render
s.exec
