# Media::Ascii::Art::C16 — Matterhorn rendered via the Ascii::Art::C16 backend.
# Fixed variant of Media::Ansi (luminance-ramp ASCII art; see sibling dirs for the palettes).
require "../../../../../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Media::Ascii::Art::C16"

CW::MediaAsciiArtC16.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../../../data/image/matterhorn.png"

CW::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Ascii::Art::C16  ·  luminance ramp · 16-color · ANSI palette{/center}", parse_tags: true,
  style: CT::Style.new(fg: "white", bg: "#202830")

s.update
s.exec
