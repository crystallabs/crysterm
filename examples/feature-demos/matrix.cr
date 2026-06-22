# IMPRESSIVE DEMO: "Matrix" digital flow.
#
# Shows off fast full-screen redraws and 24-bit color all at once: every frame
# each cell is painted straight into the screen's buffer as a packed attr with a
# direct `0xRRGGBB` foreground, so trails fade smoothly from a bright head to
# deep green with no per-cell string or tag parsing.
#
# The effect lives in the reusable `Widget::Effect::Matrix`, which fills its own
# box, reads its size lazily (so it tracks resize), and drives its own animation
# fiber — `start` to run, `stop` to halt. The whole demo is now just: make one,
# size it to the screen, and start it.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Matrix flow"

flow = Widget::Effect::Matrix.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: "black")

# Caption strip, created after the flow so it renders on top of row 0 each frame.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Full-screen 24-bit redraws — \"Matrix\" digital flow{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#0a1a0a")

flow.start

s.exec
