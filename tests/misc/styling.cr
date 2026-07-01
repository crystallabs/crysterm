# FEATURE: decorators & styling — borders, shadows, and text attributes.
#
# Styles carry fg/bg colors, border type (line or solid bg), drop shadows
# (alpha-blended), and text attributes (bold, underline, reverse), set per
# widget via `Style.new(...)` or inline `{tags}` in content.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Styling"

# Neutral backdrop so drop shadows (which darken whatever's behind a widget)
# are visible instead of black-on-black.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: 0x3a4250)

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Borders, shadows and text attributes{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

# Line border + shadow
Widget::Box.new \
  parent: s, top: 2, left: 2, width: 22, height: 5,
  content: "{center}Line border\n+ drop shadow{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#2050a0", border: Border.new(type: :line), shadow: true)

# Solid (bg) border with a shadow on all four sides. Left/right are 2 cells,
# top/bottom 1, so it looks even (terminal cells are ~2x taller than wide).
Widget::Box.new \
  parent: s, top: 2, left: 28, width: 22, height: 5,
  content: "{center}Solid bg border\n+ even shadow{/center}", parse_tags: true,
  style: Style.new(fg: "black", bg: "#d0a020", border: Border.new(type: :bg, bg: "#a07010"))

# Text attributes via inline tags
Widget::Box.new \
  parent: s, top: 2, left: 54, width: 24, height: 5,
  content: "{bold}bold{/bold} {underline}underline{/underline} {italic}italic{/italic}\n" \
           "{reverse}reverse{/reverse} {strike}strike{/strike}\n" \
           "{red-fg}red{/} {green-fg}green{/} {blue-fg}blue{/}",
  parse_tags: true,
  style: Style.new(fg: "white", bg: "#101010", border: true)

# A strip of animated 24-bit color: `Widget::Gradient` in rainbow mode,
# hue-cycling over time, driven by a shared `Timer` (can sync several widgets).
frame = Widget::Box.new \
  parent: s, top: 8, left: 2, width: 76, height: 5,
  content: "Animated 24-bit swatches:", parse_tags: true,
  style: Style.new(fg: "white", bg: "#101010", border: true)

clock = Timer.new 0.1.seconds
# `left`/`width` are relative to the frame's interior (border inset applied
# automatically), 74 cells wide. left:1 + width:72 leaves a symmetric
# one-cell margin instead of spilling over the border.
Widget::Gradient.new \
  parent: frame, top: 1, left: 1, width: 72, height: 2,
  animate: clock, speed: 0.033

s.exec
