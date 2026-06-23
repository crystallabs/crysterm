# Renders the Matterhorn as cell backgrounds in a chosen COLOR DEPTH, to show
# `Widget::Media::Ansi`'s palette quantization: TrueColor (24-bit) vs the
# xterm-256 palette vs the 16-color ANSI palette. Pick via ANSI_COLORS.
#
#   ANSI_COLORS=c256 crystal run ansi256_image.cr   # truecolor | c256 | c16
#
# (Crysterm is natively TrueColor and only reduces colors at output when the
# terminal can't do 24-bit; this *additionally* quantizes the pixels, so the
# low-color look shows even on a TrueColor terminal — the portability story.)

require "../../src/crysterm"

include Crysterm

MODES = {
  "truecolor" => {Widget::Media::Ansi::ColorMode::TrueColor, "TrueColor  ·  24-bit RGB"},
  "c256"      => {Widget::Media::Ansi::ColorMode::C256, "256-color  ·  xterm palette"},
  "c16"       => {Widget::Media::Ansi::ColorMode::C16, "16-color  ·  ANSI palette"},
}

key = ENV["ANSI_COLORS"]? || "c256"
mode, desc = MODES[key]? || MODES["c256"]

s = Screen.new title: "Media::Ansi: #{key}"

iw = s.awidth
ih = s.aheight - 1

Widget::Media::Ansi.new \
  parent: s, top: 1, left: 0, width: iw, height: ih,
  animate: false, colors: mode,
  file: "#{__DIR__}/../../screenshots/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Ansi  ·  #{desc}{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

s.render
s.exec
