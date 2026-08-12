# FEATURE: block borders & thin shadows — sub-cell, edge-anchored decoration.
#
# The line borders (see styling.cr) draw a rule through the *middle* of each
# border cell, so the widget background shows on both sides of the stroke.
# The block families anchor the ink flush to a cell edge instead, splitting
# every border cell into exactly two parts — ink and one ground:
#
#   * `:outer` — ink on the widget's outermost edge, remainder grounded in the
#     widget's own background: the interior runs up to the ink and stops.
#   * `:inner` — ink hugging the content, remainder transparent: whatever is
#     behind the widget shows right up to the ink.
#
# `Border#ratio` sets the ink thickness as a fraction of the cell *width*
# (named presets `:thin` `:quarter` `:half` `:full`); top/bottom runs divide
# by the terminal's measured cell aspect ratio (`CSS::Length.cell_aspect_ratio`)
# so all four edges come out equally thick on screen. Each side quantizes to
# what the active glyph tier can express: the default Unicode tier has every
# eighth on the bottom/left ramps but only 1/8, 4/8, 8/8 on the top/right
# ones — `:thin` and `:full` render exactly everywhere, in-between ratios
# render exactly on terminals with a modern font (kitty, WezTerm, Ghostty,
# iTerm2 — the Extended tier, via Symbols for Legacy Computing).
#
# `Shadow#ratio` is the same knob for shadows: the shadow band hugs the widget
# edge at that thickness instead of darkening whole cells.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Styling 2"

# This demo showcases the sub-cell machinery, so it pins the Extended glyph
# tier: exact eighth steps and the sextant corner pieces (Symbols for Legacy
# Computing). Interactively the tier is auto-detected (kitty, WezTerm,
# Ghostty, iTerm2 get this for free), but the headless capture would fall to
# the plain Unicode tier's coarser 1/8-4/8-8/8 steps. Comment this out on a
# terminal whose font lacks the block.
s.glyph_tier = Glyphs::Tier::Extended

# Neutral backdrop, as in styling.cr: inner borders and shadows both show
# whatever is behind the widget, which must not be black-on-black.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: 0x3a4250)

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Block borders (outer/inner) and thin shadows{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

# Outer, half-column ink (the default ratio). The border bg defaults to the
# widget's own bg, so the interior color reaches the ink with no third band
# of background outside it — compare the line borders in styling.cr, where
# the fill leaks past the stroke on both sides.
Widget::Box.new \
  parent: s, top: 3, left: 2, width: 22, height: 5,
  content: "{center}Outer block\nbg contained\n:outer, ratio: :half{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#2050a0",
    border: Border.new(type: :outer, fg: "#9fc7ff"))

# Outer hairline + thin shadow, kissing at the cell boundary: the border ink
# sits flush on the box's outer edge and the shadow tone (carried by the cell
# *background* of the band outside, so it reaches its cell edge with no
# hairline gap) starts exactly where the ink ends. `Shadow#ratio` derives the
# band glyphs that used to be hand-picked (`horizontal_char: '▄'` & co.).
Widget::Box.new \
  parent: s, top: 3, left: 28, width: 22, height: 5,
  content: "{center}Outer + thin shadow\nshadow ratio: :half\n:outer, ratio: :thin{/center}", parse_tags: true,
  style: Style.new(fg: "black", bg: "#d0a020",
    border: Border.new(type: :outer, fg: "#6b4400", ratio: :thin),
    shadow: Shadow.new(right: 1, bottom: 1, ratio: :half))

# Outer full-column: a whole column of ink on the sides and its on-screen
# equivalent (half a cell) on the top/bottom — the boldest frame, and one
# that renders identically at every glyph tier.
Widget::Box.new \
  parent: s, top: 3, left: 54, width: 24, height: 5,
  content: "{center}Outer block\nfull column\n:outer, ratio: :full{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#146054",
    border: Border.new(type: :outer, fg: "#5fe0c0", ratio: :full))

# Inner, half-column: the ink hugs the content and the cell remainder is
# transparent *by definition of the family* — no `bg: "transparent"` needed —
# so the backdrop flows up to the ink and the widget bg exists only inside it.
Widget::Box.new \
  parent: s, top: 10, left: 2, width: 22, height: 5,
  content: "{center}Inner block\nbackdrop shows\n:inner, ratio: :half{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#4a2060",
    border: Border.new(type: :inner, fg: "#d090ff"))

# Inner hairline: the widget reads as a floating content panel traced by a
# thin frame, with the backdrop everywhere else.
Widget::Box.new \
  parent: s, top: 10, left: 28, width: 22, height: 5,
  content: "{center}Inner block\nhairline ring\n:inner, ratio: :thin{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#204020",
    border: Border.new(type: :inner, fg: "#90e070", ratio: :thin))

# Variable ratio, numerically: any fraction of a column. 0.375 lands between
# the named presets; on an Extended-tier terminal both sides take the exact
# three-eighths blocks (`▍` left, Legacy Computing `🮈` right) while the
# default Unicode tier snaps each axis to the nearest step both of its ramps
# share (1/8, 4/8, 8/8), keeping opposite edges of the frame symmetric.
Widget::Box.new \
  parent: s, top: 10, left: 54, width: 24, height: 5,
  content: "{center}Outer block\nvariable ratio\n:outer, ratio: 0.375{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#601818",
    border: Border.new(type: :outer, fg: "#ff9090", ratio: 0.375))

s.exec
