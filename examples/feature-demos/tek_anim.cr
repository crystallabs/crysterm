# IMPRESSIVE DEMO: an ANIMATED image on a Tektronix 4014 storage-tube display.
#
# Same display takeover as tek_image.cr, but the source is an animated GIF. The
# 4014 storage tube can't update in place, so every frame is a full PAGE-clear +
# vector redraw — it visibly flickers, which is inherent to the hardware, not a
# bug. Animation uses ordered (Bayer) dithering by default (`Dither::Auto` picks
# it for animated sources) because it is frame-independent: the same pixels
# dither identically every frame, so the picture stays stable. Floyd–Steinberg
# error diffusion (the default for a *still*) would "boil"/shimmer here.
#
# Override the method with TEK_DITHER=ordered|diffusion|none, speed with
# TEK_SPEED, size with TEK_FIT. Needs an xterm with --enable-tek4014; watch the
# separate "tektronix" window.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Tek anim"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  content: "{center}Image::Tek · animated GIF on a Tektronix 4014 · see the separate \"tektronix\" window{/center}",
  parse_tags: true, style: Style.new(fg: "#33ff66", bg: "black")

dither = case ENV["TEK_DITHER"]?
         when "ordered"   then Widget::Image::Tek::Dither::Ordered
         when "diffusion" then Widget::Image::Tek::Dither::Diffusion
         when "none"      then Widget::Image::Tek::Dither::None
         else                  Widget::Image::Tek::Dither::Auto # -> Ordered for animation
         end

fit = case ENV["TEK_FIT"]?
      when "stretch" then Widget::Image::Fit::Stretch
      when "cover"   then Widget::Image::Fit::Cover
      else                Widget::Image::Fit::Contain
      end

Widget::Image::Tek.new \
  parent: s,
  fit: fit,
  speed: (ENV["TEK_SPEED"]? || "1.0").to_f,
  dither: dither,
  file: "#{__DIR__}/../../screenshots/netscape.gif"

if secs = ENV["DEMO_SECONDS"]?
  spawn do
    sleep secs.to_f.seconds
    s.destroy
    exit
  end
end

s.render
s.exec
