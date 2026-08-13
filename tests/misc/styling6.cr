# FEATURE: Thick bands, block patterns, and separators.
#
# Part of the borders demo set (guide: ../../README-borders.md).
#
# Row 1 — band alignment at side widths >= 2: the `align` axis picks which
# ring of the band carries the rule. `:outer` rules the rim (band ground
# inside it), `:center` repeats the rule through every band cell (the
# classic thick-border geometry), `:inner` rules only the content-hugging
# ring — and a block `Double` pattern rules rim *and* content rings, the
# two-ring frame a single cell can't express.
#
# Row 2 — block-type patterns: dashed and dotted block borders gap whole
# run cells (dotted 1:1, dashed 2:1, phase-locked to the corners, which
# always ink), at any `ratio`; plus the block corner beads.
#
# Row 3 — separators: `Widget::HLine`/`VLine` speak the same axes
# (`type:`/`pattern:`/`ratio:`), deriving heavy/dashed/double line rules,
# block ramp rules, and braille rules — centered dot-rows horizontally, a
# braille exclusive no box-drawing glyph can match.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Styling 6"

# Extended tier pinned for the block eighths and braille rules, as in
# styling2-5.cr.
s.glyph_tier = Glyphs::Tier::Extended

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: 0x3a4250)

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Thick bands, block patterns, separators{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

COLORS = [
  {0x2050a0, "#9fc7ff"}, {0x146054, "#5fe0c0"}, {0x4a2060, "#d090ff"},
  {0x204020, "#90e070"}, {0x601818, "#ff9090"}, {0x585020, "#e0d878"},
  {0x14505c, "#70cce0"}, {0x50285c, "#cc88e8"},
]

# Row 1: 2-cell bands (3-cell for the two-ring), height 7 so a labeled
# interior survives the thick band.
row1 = [
  {Border.new(align: :outer, left: 2, top: 2, right: 2, bottom: 2), # rim ring, band ground inside
   "align: :outer"},
  {Border.new(align: :center, left: 2, top: 2, right: 2, bottom: 2), # the classic repeat
   "align: :center"},
  {Border.new(align: :inner, left: 2, top: 2, right: 2, bottom: 2), # content-hugging ring
   "align: :inner"},
  {Border.new(type: :block, pattern: :double, ratio: :full, left: 3, top: 3, right: 3, bottom: 3), # rim + content rings
   "2-ring"},
]
row1.each_with_index do |(border, label), i|
  bg, fg = COLORS[i]
  border.fg = fg
  Widget::Box.new \
    parent: s, top: 2, left: 1 + i * 20, width: 18, height: 7,
    content: "{center}#{label}{/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg, border: border)
end

# Row 2: block patterns and beads.
row2 = [
  {Border.new(type: :block, pattern: :dotted, ratio: :full), # 1 ink : 1 ground cell
   "block :dotted\nratio: :full"},
  {Border.new(type: :block, pattern: :dashed, ratio: :full), # 2 ink : 1 ground
   "block :dashed\nratio: :full"},
  {Border.new(type: :block, pattern: :dotted, ratio: :half), # gaps at any thickness
   "block :dotted\nratio: :half"},
  {Border.new(type: :outer, ratio: :thin, corner_ratio: :full), # full-block corner mounts
   "corner_ratio:\n:full (beads)"},
]
row2.each_with_index do |(border, label), i|
  bg, fg = COLORS[4 + i]
  border.fg = fg
  Widget::Box.new \
    parent: s, top: 10, left: 1 + i * 20, width: 18, height: 5,
    content: "{center}#{label}{/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg, border: border)
end

# Row 3: separator groups — a label row over three rules each, drawn by
# `Widget::HLine` from the same axes (an explicit `char:` would still pin).
SEPARATORS = [
  {"line: rules", [
    {type: :line, pattern: :solid, ratio: 0.5},  # ─
    {type: :line, pattern: :solid, ratio: 1.0},  # ━ (heavy above 1/2)
    {type: :line, pattern: :double, ratio: 0.5}, # ═
  ]},
  {"line: dashes", [
    {type: :line, pattern: :dashed, ratio: 0.5}, # ┄
    {type: :line, pattern: :dotted, ratio: 0.5}, # ┈
    {type: :line, pattern: :dotted, ratio: 1.0}, # ┉ (heavy dotted)
  ]},
  {"block: ramps", [
    {type: :block, pattern: :solid, ratio: 0.25}, # ▁
    {type: :block, pattern: :solid, ratio: 0.5},  # ▂
    {type: :block, pattern: :solid, ratio: 1.0},  # ▄
  ]},
  {"braille: rules", [
    {type: :braille, pattern: :solid, ratio: 0.5},  # ⠒ centered dot-row
    {type: :braille, pattern: :solid, ratio: 1.0},  # ⠶ two centered rows
    {type: :braille, pattern: :dotted, ratio: 0.5}, # ⠂ sparse
  ]},
]

SEPARATORS.each_with_index do |(label, rules), i|
  bg, fg = COLORS[i]
  panel = Widget::Box.new \
    parent: s, top: 17, left: 1 + i * 20, width: 18, height: 5,
    content: "{center}#{label}{/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg)
  rules.each_with_index do |axes, j|
    Widget::HLine.new parent: panel, top: 1 + j, left: 1, width: 16,
      type: axes[:type], pattern: axes[:pattern], ratio: axes[:ratio],
      style: Style.new(fg: fg, bg: bg)
  end
end

s.exec
