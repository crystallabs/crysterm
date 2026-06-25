# IMPRESSIVE DEMO: a true-color image as in-band SIXEL graphics.
#
# `Widget::Media::Sixel` decodes the PNG with the pure-Crystal PNGGIF reader,
# quantizes it to a 252-color palette (Bayer-dithered), and emits a DCS sixel
# sequence that a sixel-capable terminal (xterm -ti vt340, foot, wezterm, …)
# renders as real raster pixels — right inside the VT window, on top of the
# cells, with no external helper. Here: the Matterhorn.
#
# This needs a sixel-capable terminal on a real display; it does NOT render
# through a plain pipe/pseudo-terminal.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Sixel"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Media::Sixel  ·  in-band DCS sixel raster graphics  ·  the Matterhorn{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

# Leave the title row at the top AND one row free at the bottom: sixel scrolling
# advances the cursor below the image, so a sixel reaching the last screen row
# would scroll the title off the top. One spare row keeps the cursor on-screen.
iw = s.awidth
ih = s.aheight - 2

fit = case ENV["FIT"]?
      when "contain" then Widget::Media::Fit::Contain
      when "cover"   then Widget::Media::Fit::Cover
      else                Widget::Media::Fit::Stretch
      end

Widget::Media::Sixel.new \
  parent: s, top: 1, left: 0, width: iw, height: ih,
  fit: fit,
  cell_pixel_width: (ENV["CELL_PW"]? || "0").to_i,  # 0 = auto-detect (TIOCGWINSZ)
  cell_pixel_height: (ENV["CELL_PH"]? || "0").to_i, # so the raster matches real cells
  file: "#{__DIR__}/../../data/image/matterhorn.png"

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
