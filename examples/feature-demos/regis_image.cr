# IMPRESSIVE DEMO: an image as in-band ReGIS vector graphics.
#
# `Widget::Image::Regis` decodes the PNG, quantizes it to ReGIS's built-in named
# colors, and emits a DCS ReGIS command stream (one run of horizontal vectors
# per scan line) that a ReGIS-capable terminal (xterm built with
# --enable-regis-graphics, or a real VT340) draws into the VT window. The result
# is a posterized, period-accurate ReGIS rendering of the Matterhorn.
#
# Needs a ReGIS-capable terminal on a real display.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Regis"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Image::Regis  ·  in-band ReGIS vector graphics  ·  the Matterhorn{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

iw = s.awidth
ih = s.aheight - 1

# ReGIS addresses a fixed logical screen that xterm maps onto the whole text
# area; set the matching `XTerm*regisScreenSize` resource so it fills the window.
Widget::Image::Regis.new \
  parent: s, top: 1, left: 0, width: iw, height: ih,
  dither: (ENV["REGIS_DITHER"]? == "1"),
  regis_width: (ENV["REGIS_W"]? || "0").to_i,  # 0 = auto (match the window via TIOCGWINSZ)
  regis_height: (ENV["REGIS_H"]? || "0").to_i,
  file: "#{__DIR__}/../../screenshots/matterhorn.png"

if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.render
s.exec
