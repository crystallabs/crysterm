# FEATURE: image rendering as terminal cells (ANSI), incl. animated GIF/APNG.
#
# `Widget::Image::Ansi` decodes PNG / APNG / GIF with the pure-Crystal PNGGIF
# reader and draws each downscaled pixel as one TrueColor cell — no external
# helpers needed. Animated images play automatically.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Image"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Images decoded to TrueColor cells (static PNG + animated GIF){/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#203040")

Widget::Box.new \
  parent: s, top: 1, left: 2, width: 34, height: 2,
  content: "{center}static PNG{/center}", parse_tags: true,
  style: Style.new(fg: "cyan")
Widget::Image::Ansi.new \
  parent: s, top: 3, left: 2, width: 34, height: 11,
  file: "#{__DIR__}/assets/sample.png"

Widget::Box.new \
  parent: s, top: 1, left: 42, width: 34, height: 2,
  content: "{center}animated GIF{/center}", parse_tags: true,
  style: Style.new(fg: "magenta")
Widget::Image::Ansi.new \
  parent: s, top: 3, left: 42, width: 34, height: 11,
  file: "#{__DIR__}/assets/spin.gif"

# Keep the screen refreshing so the animated GIF advances on the recording.
s.every(0.08.seconds) { }

s.exec
