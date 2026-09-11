# Media::Ansi — Matterhorn rendered as cell backgrounds, one cell per pixel,
# in the default colormode. Sibling dirs pin one colormode each
# (truecolor / c256 / c16 / c8).
require "../../../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Media::Ansi"

CW::MediaAnsi.new \
  parent: s, top: 1, left: 0, width: s.awidth, height: s.aheight - 1,
  animate: false,
  file: "#{__DIR__}/../../../../data/image/matterhorn.png"

CW::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Ansi  ·  one cell per pixel · default colormode{/center}", parse_tags: true,
  style: CT::Style.new(fg: "white", bg: "#202830")

s.update
s.exec
