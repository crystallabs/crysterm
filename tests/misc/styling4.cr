# FEATURE: Braille borders — dotted sub-cell rings.
#
# A `BorderType::Braille` border draws its ink as Braille Patterns (U+2800..):
# each run is the braille pattern whose dot-columns (left/right) or dot-rows
# (top/bottom) hug the widget's outermost cell edges — anchored like `:outer`,
# and grounded the same way, in the widget's own background — while each
# corner is the union of its two adjoining runs' dot masks, so the ring
# closes flush by construction. `Border#ratio` sizes the ink in dot-lines on
# the braille grid's 2 dot-columns x 4 dot-rows resolution
# (`Glyphs.braille_steps`, aspect-compensated like the block families of
# styling2/styling3.cr — which quantizes coarsely: up to `:half` a single
# dot-line on every edge, `:full` the whole two-column band).
#
# The eight boxes tour the family: both thickness steps on both grounds
# (widget bg and transparent), per-side colors, relief shading, sparse-dot
# char overrides, and a 2-cell-wide band.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Styling 4"

# Braille Patterns are Extended-tier repertoire (the same taxonomy as the
# braille spinner frames), pinned here for the headless capture — below
# Extended the border degrades to the Dotted line family's glyphs.
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
  content: "{center}Braille borders — dot rings, grounds, colors, patterns{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

# Same {bg, border fg} palette as styling2/3.cr, so the families compare
# box-for-box.
COLORS = [
  {0x2050a0, "#9fc7ff"}, {0x146054, "#5fe0c0"}, {0x4a2060, "#d090ff"},
  {0x204020, "#90e070"}, {0x601818, "#ff9090"}, {0x585020, "#e0d878"},
  {0x14505c, "#70cce0"}, {0x50285c, "#cc88e8"},
]

# Per-side colors: an explicit side fg override outranks the whole-border fg
# (the corners follow the top/bottom side they sit on).
sides = Border.new(type: :braille, ratio: :full)
sides.top_fg = 0xff9090
sides.right_fg = 0x90e070
sides.bottom_fg = 0x9fc7ff
sides.left_fg = 0xe0d878

# Relief shading: the light source sits top-left, so `:outset` lights the
# top/left dots and shades the bottom/right ones.
relief = Border.new(type: :braille, ratio: :full)
relief.relief = Border::Relief::Outset

# Sparse dots via the char-override chain: half-density runs (every other
# dot dropped), the derived corner patterns kept.
sparse = Border.new(type: :braille, ratio: :half)
sparse.top_char = '⠁'
sparse.bottom_char = '⡀'
sparse.left_char = '⠅'
sparse.right_char = '⠨'

# Each box's border and label; bg + border fg step through COLORS.
boxes = [
  {Border.new(type: :braille, ratio: :half),
   "type: :braille\nratio: :half\n(1 dot-line)"},
  {Border.new(type: :braille, ratio: :full),
   "type: :braille\nratio: :full\n(2 dot-lines)"},
  {Border.new(type: :braille, ratio: :half, bg: "transparent"),
   "type: :braille\nbg: transparent\nratio: :half"},
  {Border.new(type: :braille, ratio: :full, bg: "transparent"),
   "type: :braille\nbg: transparent\nratio: :full"},
  {sides,
   "type: :braille\nper-side colors\n(fg per edge)"},
  {relief,
   "type: :braille\nrelief: :outset\n(lit/shaded)"},
  {sparse,
   "type: :braille\nchar overrides\n(sparse dots)"},
  # A 2-cell-thick band: every band cell repeats its run's dot-line, giving
  # concentric dotted tracks. Only one interior row remains, hence the
  # one-line label.
  {Border.new(type: :braille, ratio: :half, left: 2, top: 2, right: 2, bottom: 2),
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
