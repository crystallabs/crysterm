# Renders the Matterhorn as cell backgrounds in a chosen COLOR DEPTH, to show
# `Widget::ANSIImage`'s palette quantization: TrueColor (24-bit) vs the
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
  "truecolor" => {Widget::ANSIImage::ColorMode::TrueColor, "TrueColor  ·  24-bit RGB"},
  "c256"      => {Widget::ANSIImage::ColorMode::C256, "256-color  ·  xterm palette"},
  "c16"       => {Widget::ANSIImage::ColorMode::C16, "16-color  ·  ANSI palette"},
}

key = ENV["ANSI_COLORS"]? || "c256"
mode, desc = MODES[key]? || MODES["c256"]

s = Screen.new title: "ANSIImage: #{key}"
s.show_fps = nil

iw = s.awidth
ih = s.aheight - 1

Widget::ANSIImage.new \
  parent: s, top: 1, left: 0, width: iw, height: ih,
  animate: false, colors: mode,
  file: "#{__DIR__}/../../screenshots/matterhorn.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}ANSIImage  ·  #{desc}{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#202830")

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

s.render
s.exec
