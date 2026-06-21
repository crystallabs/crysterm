# DEMO: an ANIMATED image in a RESIZING box. The animation keeps playing while
# the box oscillates in size, and each shown frame is re-sampled to the current
# box — lazily and cached per size, so resizing doesn't regenerate every frame.
#
# Load a different image with the IMAGE env var, e.g.:
#   IMAGE=screenshots/netscape.gif crystal run resize_anim.cr

require "../../src/crysterm"

include Crysterm

img_path = ENV["IMAGE"]? || "#{__DIR__}/assets/spin.gif"

s = Screen.new title: "Resize (animated)"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Animated image re-sampling into a resizing box (fit: Contain){/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

img = Widget::Image::Ansi.new \
  parent: s, top: 2, left: 2, width: 16, height: 8,
  fit: Widget::Image::Fit::Contain,
  file: img_path,
  style: Style.new(border: true)

maxw = s.awidth - 4
maxh = s.aheight - 4
t = 0.0
s.every(0.06.seconds) do
  phase = t % 2.0
  f = phase < 1.0 ? phase : 2.0 - phase
  img.width = (12 + (maxw - 12) * f).to_i
  img.height = (4 + (maxh - 4) * f).to_i
  t += 0.06
end

s.render
s.exec
