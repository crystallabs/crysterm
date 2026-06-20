# IMPRESSIVE DEMO: a full-color PNG rendered as TrueColor cells.
#
# `Widget::ANSIImage` decodes the PNG with the pure-Crystal PNGGIF reader and
# paints each downscaled pixel as one 24-bit terminal cell — no external
# helpers. Here: Yellowstone's Grand Prismatic Spring, cropped to fill the
# standard 80x15 window.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "PNG image"
s.show_fps = nil

# ANSIImage only honors *concrete integer* width/height as cell targets, so we
# compute them from the actual screen size and fill the area below the title.
iw = s.awidth
ih = s.aheight - 1

Widget::ANSIImage.new \
  parent: s, top: 1, left: 0, width: iw, height: ih,
  animate: false,
  file: "#{__DIR__}/../../screenshots/prismatic.png"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}TrueColor PNG -> terminal cells  ·  Grand Prismatic Spring{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#101820")

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

s.render
s.exec
