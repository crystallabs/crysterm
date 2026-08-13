# FEATURE: Shadow anatomy — the drop shadow's own knobs.
#
# Part of the borders demo set (guide: ../../README-borders.md; the
# light-*driven* behaviors — direction flips, looks — are styling5.cr's
# topic, this file is the `Shadow` object itself).
#
# Row 1 — placement and tone: explicit per-side extents, the auto-placed
# `shadow: true` (sides follow the scene light — identical to the classic
# right/bottom under the default NW), and the `opacity` blend at both ends.
#
# Row 2 — the thin (`ratio:`) ladder: bands hug the widget edge at a
# sub-cell thickness (the same unit and aspect compensation as
# `Border#ratio`), deriving their half-block glyphs automatically; `:full`
# degrades side bands to the classic whole-cell blend.
#
# Row 3 — the rest of the surface: hand-picked band chars (the pre-`ratio`
# spelling, still honored), the directional-vs-spot silhouettes side by
# side, and `look: :floating` bundling a thin auto shadow in one keyword.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Styling 7"

# Extended tier pinned for the exact thin-shadow eighths, as in styling2-6.cr.
s.glyph_tier = Glyphs::Tier::Extended

# Neutral backdrop: shadows darken whatever is behind the widget.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: 0x3a4250)

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Shadow anatomy — sides, opacity, thin ratios, chars{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

COLORS = [
  {0x2050a0, "#9fc7ff"}, {0x146054, "#5fe0c0"}, {0x4a2060, "#d090ff"},
  {0x204020, "#90e070"}, {0x601818, "#ff9090"}, {0x585020, "#e0d878"},
  {0x14505c, "#70cce0"}, {0x50285c, "#cc88e8"}, {0x1c3a5c, "#7fb2e8"},
  {0x355020, "#b0d878"}, {0x5c2038, "#e888ac"}, {0x20504a, "#78d8c4"},
]

# Each entry: {shadow or full style, 1-3 label lines}.
boxes = [
  # Row 1 — placement and tone.
  {Shadow.new(right: 2, bottom: 1), # the classic explicit extents
   "explicit sides\nright: 2\nbottom: 1"},
  {Shadow.new, # no sides given: the light places it (NW -> same as classic)
   "shadow: true\n(auto sides)"},
  {Shadow.new(right: 2, bottom: 1, opacity: 0.25), # a whisper of a shadow
   "opacity: 0.25"},
  {Shadow.new(right: 2, bottom: 1, opacity: 0.85), # near-black
   "opacity: 0.85"},
  # Row 2 — the thin ratio ladder.
  {Shadow.new(right: 1, bottom: 1, ratio: :thin), # hairline band
   "ratio: :thin"},
  {Shadow.new(right: 1, bottom: 1, ratio: :quarter),
   "ratio: :quarter"},
  {Shadow.new(right: 1, bottom: 1, ratio: :half), # the sweet spot
   "ratio: :half"},
  {Shadow.new(right: 1, bottom: 1, ratio: :full), # side bands: whole-cell blend
   "ratio: :full"},
  # Row 3 — chars, silhouettes, the bundled look.
  {Shadow.new(right: 1, bottom: 1, horizontal_char: '▄'), # hand-picked band glyphs
   "horizontal_char\n'▄' (manual)"},
  {Style.new(border: true, shadow: true, light: :n), # exact silhouette below
   "light: :n\n(directional)"},
  {Style.new(border: true, shadow: true, light: Light.new(:n, :spot)), # spills 1 cell each side
   "light: n spot\n(cone spill)"},
  {Style.new(border: Border.new(type: :rounded), look: :floating), # thin auto shadow, one keyword
   "look: :floating"},
]

boxes.each_with_index do |(deco, label), i|
  bg, fg = COLORS[i]
  style =
    case deco
    in Shadow then Style.new(border: Border.new(fg: fg), shadow: deco)
    in Style  then deco
    end
  style.fg = "white"
  style.bg = bg
  style.border.fg = fg if style.border.fg.nil?
  Widget::Box.new \
    parent: s, top: 2 + (i // 4) * 7, left: 2 + (i % 4) * 20, width: 17, height: 5,
    content: "{center}#{label}{/center}", parse_tags: true,
    style: style
end

s.exec
