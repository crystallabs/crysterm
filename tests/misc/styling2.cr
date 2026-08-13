# FEATURE: Outer block borders — the full thickness ladder.
#
# Part of the borders demo set (guide: ../../README-borders.md). In axis
# terms these boxes are `medium: :block, align: :outer`, thickness stepped
# through `ratio`.
#
# A `BorderType::Outer` border draws its ink as edge-anchored block glyphs
# flush with the widget's outermost cell edges, grounding each border cell's
# remainder in the widget's own background: the interior color runs up to the
# ink and stops, splitting every border cell into exactly two parts (compare
# the line borders in styling.cr, whose centered rule has background on both
# sides). `Border#ratio` sets the ink thickness as a fraction of the cell
# *width*; top/bottom runs divide by the terminal's measured cell aspect
# ratio (`CSS::Length.cell_aspect_ratio`) so all four edges come out equally
# thick on screen.
#
# The eight boxes below step `ratio` through every eighth, 1/8 → 8/8. Corner
# joints resolve per thickness (`Border#outer_block_corners`): eighth-L
# pieces, sextant elbows, quadrant blocks, then the full block — and where
# sextant corners are in play their third-tall arms pull the horizontal runs
# up to matching third-blocks, keeping every joint flush.
#
# The `:inner` transpose of this ladder lives in styling3.cr.

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
# Octant corner pieces (Unicode 16) are likewise pinned on: normally
# auto-detected per terminal (`Tput::Emulator::OCTANT_SUPPORT`; e.g.
# kitty ≥ 0.40), and the capture font covers them. They make the `:half`
# geometry pixel-exact without the thirds re-quantization.
s.glyph_octants = true

# Neutral backdrop so the frames don't sit black-on-black.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: 0x3a4250)

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Outer block borders — ratio: 1/8 .. 8/8{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

# One {bg, border fg} pair per eighth, hue-stepped for telling them apart.
COLORS = [
  {0x2050a0, "#9fc7ff"}, {0x146054, "#5fe0c0"}, {0x4a2060, "#d090ff"},
  {0x204020, "#90e070"}, {0x601818, "#ff9090"}, {0x585020, "#e0d878"},
  {0x14505c, "#70cce0"}, {0x50285c, "#cc88e8"},
]

8.times do |i|
  ratio = (i + 1) / 8.0
  bg, fg = COLORS[i]
  Widget::Box.new \
    parent: s, top: 2 + (i // 4) * 7, left: 1 + (i % 4) * 20, width: 18, height: 5,
    content: "{center}type: :outer\nratio: #{ratio}\n(#{i + 1}/8 column){/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg, border: Border.new(type: :outer, fg: fg, ratio: ratio))
end

s.exec
