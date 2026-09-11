# FEATURE: image rendering as terminal cells (ANSI), incl. animated GIF/APNG.
#
# `Widget::Media::Ansi` decodes PNG / APNG / GIF with the pure-Crystal PNGGIF
# reader and draws each downscaled pixel as one TrueColor cell — no external
# helpers needed. Animated images play automatically.

require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

s = CT::Window.new title: "Media"

CW::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Images decoded to TrueColor cells (static PNG + animated GIF){/center}",
  parse_tags: true, style: CT::Style.new(fg: "white", bg: "#203040")

CW::Box.new \
  parent: s, top: 1, left: 2, width: 34, height: 2,
  content: "{center}static PNG{/center}", parse_tags: true,
  style: CT::Style.new(fg: "cyan")
CW::MediaAnsi.new \
  parent: s, top: 3, left: 2, width: 34, height: 12,
  file: "#{__DIR__}/../../data/image/matterhorn.png"

CW::Box.new \
  parent: s, top: 1, left: 42, width: 34, height: 2,
  content: "{center}animated GIF{/center}", parse_tags: true,
  style: CT::Style.new(fg: "magenta")
CW::MediaAnsi.new \
  parent: s, top: 3, left: 42, width: 34, height: 12,
  file: "#{__DIR__}/../../data/image/netscape.gif"

# Keep the screen refreshing so the animated GIF advances on the recording.
s.every(0.08.seconds) { }

s.exec
