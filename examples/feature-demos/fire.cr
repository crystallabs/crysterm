# IMPRESSIVE DEMO: "Fire" — a rising, flickering flame wall.
#
# Shows off fast full-screen redraws and 24-bit color: the entire screen is
# recomposed every frame as a single tagged string. The bottom row is reseeded
# with random embers each frame and every cell above cools to a blend of the
# hotter cells just below it, so heat rises and fades — mapped through a
# black → red → orange → yellow → white ramp, with cold cells left blank so the
# flame's silhouette shows through.
#
# The effect lives in the reusable `Widget::Effect::Fire`, which fills its own
# box, reads its size lazily (so it tracks resize), and drives its own animation
# fiber — `start` to run, `stop` to halt. The whole demo is now just: make one,
# size it to the screen, and start it.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Fire"
s.show_fps = nil

fire = Widget::Effect::Fire.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: "black")

fire.start

s.exec
