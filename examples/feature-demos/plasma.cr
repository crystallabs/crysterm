# IMPRESSIVE DEMO: "Plasma" — a slowly-undulating, rainbow-marbled field.
#
# Shows off fast full-screen redraws and 24-bit color: the entire screen is
# recomposed every frame as a single tagged string, where each cell's hue is a
# pure function of its position and the frame counter — several sine waves
# (horizontal, vertical, diagonal, and a radial ripple around the centre) summed
# and mapped onto the color wheel, so the whole area churns through a seamless
# rainbow with no per-cell state.
#
# The effect lives in the reusable `Widget::Effect::Plasma`, which fills its own
# box, reads its size lazily (so it tracks resize), and drives its own animation
# fiber — `start` to run, `stop` to halt. The whole demo is now just: make one,
# size it to the screen, and start it.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Plasma"
s.show_fps = nil

plasma = Widget::Effect::Plasma.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: "black")

plasma.start

s.exec
