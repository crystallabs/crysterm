# FEATURE: Braille borders — dotted sub-cell rings, across the stroke axes.
#
# Part of the borders demo set (guide: ../../README-borders.md).
#
# A `Border::Medium::Braille` border draws its ink as Braille Patterns
# (U+2800..): each run is the braille pattern whose dot-columns (left/right)
# or dot-rows (top/bottom) hug a cell edge, and each corner is the union of
# its two adjoining runs' dot masks, so the ring closes flush by
# construction. `Border#ratio` sizes the ink in dot-lines on the braille
# grid's 2 dot-columns x 4 dot-rows resolution (`Glyphs.braille_steps`,
# aspect-compensated like the block families of styling2/styling3.cr).
#
# Since the border API's decomposition into stroke axes (plans/BORDERS.md),
# braille composes with all of them, and the twelve boxes tour that:
# thickness and grounds (row 1), colors, relief and the sparse patterns
# (row 2), and the corner treatments (row 3) — including `corner_ratio`'s
# full-dot corner beads and a 2-cell-wide band.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Styling 4"

# Braille Patterns are Extended-tier repertoire (the same taxonomy as the
# braille spinner frames), pinned here for the headless capture — below
# Extended the border degrades to the dotted/dashed line families.
# Interactively the tier is auto-detected. Comment this out on a terminal
# whose font lacks the block.
s.glyph_tier = Glyphs::Tier::Extended

# Neutral backdrop so the frames don't sit black-on-black — and so the
# transparent-ground boxes have something to float on.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: 0x3a4250)

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Braille borders — dot rings across the stroke axes{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

# The styling2/3.cr palette, extended by four pairs for the third row.
COLORS = [
  {0x2050a0, "#9fc7ff"}, {0x146054, "#5fe0c0"}, {0x4a2060, "#d090ff"},
  {0x204020, "#90e070"}, {0x601818, "#ff9090"}, {0x585020, "#e0d878"},
  {0x14505c, "#70cce0"}, {0x50285c, "#cc88e8"}, {0x1c3a5c, "#7fb2e8"},
  {0x355020, "#b0d878"}, {0x5c2038, "#e888ac"}, {0x20504a, "#78d8c4"},
]

# Per-side colors: an explicit side fg override outranks the whole-border fg
# (the corners follow the top/bottom side they sit on).
sides = Border.new(type: :braille, ratio: :full)
sides.top_fg = 0xff9090
sides.right_fg = 0x90e070
sides.bottom_fg = 0x9fc7ff
sides.left_fg = 0xe0d878

# Each box's border and label; bg + border fg step through COLORS.
boxes = [
  {Border.new(type: :braille, ratio: :half),
   "type: :braille\nratio: :half\n(1 dot-line)"},
  {Border.new(type: :braille, ratio: :full),
   "type: :braille\nratio: :full\n(2 dot-lines)"},
  {Border.new(type: :braille, ratio: :full, bg: "transparent"),
   "type: :braille\nbg: transparent\nratio: :full"},
  # Inner alignment: ink hugs the content, ground transparent by default —
  # the ring floats on the backdrop, snug against the panel.
  {Border.new(type: :braille, align: :inner),
   "type: :braille\nalign: :inner\n(hugs content)"},
  {sides,
   "type: :braille\nper-side colors\n(fg per edge)"},
  {Border.new(type: :braille, ratio: :full, relief: :outset),
   "type: :braille\nrelief: :outset\n(lit/shaded)"},
  # The sparse patterns replace styling4's original char-override hack.
  {Border.new(type: :braille, pattern: :dotted),
   "type: :braille\npattern: :dotted\n(sparse dots)"},
  {Border.new(type: :braille, pattern: :dashed),
   "type: :braille\npattern: :dashed\n(column dashes)"},
  {Border.new(type: :braille, corners: :rounded),
   "type: :braille\ncorners: rounded\n(apex dot off)"},
  {Border.new(type: :braille, corners: :cut),
   "type: :braille\ncorners: :cut\n(diagonal dots)"},
  {Border.new(type: :braille, ratio: :half, corner_ratio: :full),
   "type: :braille\ncorner_ratio:\n:full (beads)"},
  # A 2-cell-thick band with `align: :center` — the thick-band alignment
  # that repeats the run through every band cell, giving concentric dotted
  # tracks (the default `:outer` would rule only the band's rim ring).
  # Only one interior row remains, hence the one-line label.
  {Border.new(type: :braille, ratio: :half, align: :center, left: 2, top: 2, right: 2, bottom: 2),
   "2-cell band"},
]

boxes.each_with_index do |(border, label), i|
  bg, fg = COLORS[i]
  border.fg = fg
  Widget::Box.new \
    parent: s, top: 2 + (i // 4) * 7, left: 1 + (i % 4) * 20, width: 18, height: 5,
    content: "{center}#{label}{/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg, border: border)
end

s.exec
