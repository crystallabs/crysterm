# IMPRESSIVE DEMO: a true-color image via the KITTY graphics protocol.
#
# `Widget::KittyImage` decodes the PNG with the pure-Crystal PNGGIF reader and
# transmits it as raw 32-bit RGBA (base64, chunked) in an in-band APC escape
# (`ESC _G … ESC \`) that a Kitty-protocol terminal (kitty, WezTerm, Konsole,
# Ghostty, …) draws as real pixels — full true-color, no palette, scaled by the
# terminal to fill the widget's cell box. Here: the Matterhorn.
#
# This needs a Kitty-graphics-capable terminal on a real display.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "KittyImage"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}KittyImage  ·  Kitty graphics protocol, true-color RGBA  ·  the Matterhorn{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

iw = s.awidth
ih = s.aheight - 1

Widget::KittyImage.new \
  parent: s, top: 1, left: 0, width: iw, height: ih,
  cell_pixel_width: (ENV["CELL_PW"]? || "11").to_i,
  cell_pixel_height: (ENV["CELL_PH"]? || "22").to_i,
  file: "#{__DIR__}/../../screenshots/matterhorn.png"

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.render
s.exec
