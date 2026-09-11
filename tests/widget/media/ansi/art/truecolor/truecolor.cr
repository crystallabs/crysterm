# Media::Ascii::Art::TrueColor — Matterhorn rendered via the Ascii::Art::TrueColor backend.
# Fixed variant of Media::Ansi (luminance-ramp ASCII art; see sibling dirs for the palettes).
require "../../../../../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Media::Ascii::Art::TrueColor"

CW::MediaAsciiArtTrueColor.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../../../data/image/matterhorn.png"

CW::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Ascii::Art::TrueColor  ·  luminance ramp · 24-bit RGB{/center}", parse_tags: true,
  style: CT::Style.new(fg: "white", bg: "#202830")

s.update
s.exec
