# IMPRESSIVE DEMO: a true-color image as in-band SIXEL graphics.
#
# `Widget::SixelImage` decodes the PNG with the pure-Crystal PNGGIF reader,
# quantizes it to a 252-color palette (Bayer-dithered), and emits a DCS sixel
# sequence that a sixel-capable terminal (xterm -ti vt340, foot, wezterm, …)
# renders as real raster pixels — right inside the VT window, on top of the
# cells, with no external helper. Here: the Matterhorn.
#
# This needs a sixel-capable terminal on a real display; it does NOT render
# through a plain pipe/pseudo-terminal.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "SixelImage"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}SixelImage  ·  in-band DCS sixel raster graphics  ·  the Matterhorn{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

iw = s.awidth
ih = s.aheight - 1

fit = case ENV["FIT"]?
      when "contain" then Widget::Image::Fit::Contain
      when "cover"   then Widget::Image::Fit::Cover
      else                Widget::Image::Fit::Stretch
      end

Widget::SixelImage.new \
  parent: s, top: 1, left: 0, width: iw, height: ih,
  fit: fit,
  cell_pixel_width: (ENV["CELL_PW"]? || "11").to_i,
  cell_pixel_height: (ENV["CELL_PH"]? || "22").to_i,
  file: "#{__DIR__}/../../screenshots/matterhorn.png"

s.on(Event::KeyPress) do |e|
  if e.char == 'q' || e.key == Tput::Key::CtrlQ
    s.destroy
    exit
  end
end

# Self-terminate for the screenshot tooling (so nothing external must be killed).
if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.render
s.exec
