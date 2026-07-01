# Media::Ascii::Art::C8 — Matterhorn rendered via the Ascii::Art::C8 backend.
# Fixed variant of Media::Ansi (luminance-ramp ASCII art; see sibling dirs for the palettes).
require "../../../../../../src/crysterm"

include Crysterm

s = Window.new title: "Media::Ascii::Art::C8"

Widget::Media::Ascii::Art::C8.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../../../data/image/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Ascii::Art::C8  ·  luminance ramp · 8-color · base ANSI palette{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

s.render
s.exec
