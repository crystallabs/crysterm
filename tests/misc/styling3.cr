# FEATURE: Inner block borders — the full thickness ladder.
#
# Part of the borders demo set (guide: ../../README-borders.md). In axis
# terms these boxes are `medium: :block, align: :inner`, thickness stepped
# through `ratio`.
#
# The `:inner` transpose of styling2.cr: a `BorderType::Inner` border anchors
# its ink flush with the *content*, and the border cells' remainder is
# transparent by definition of the family — whatever is behind the widget
# shows right up to the ink, so the widget reads as a content panel traced by
# a ring floating on the backdrop. The widget's own background exists only
# inside the ring.
#
# The eight boxes step `Border#ratio` through every eighth, 1/8 → 8/8
# (fraction of the cell width; top/bottom runs aspect-compensated). Inner
# corner joints resolve through the spill-minimizing `Glyphs.corner_fit`:
# hairline rings leave the corner cells untouched (the strokes already meet
# corner to corner), middling steps take the sextant miter pieces (pulling
# the runs up to matching third-blocks), and thick rings continue the
# horizontal stroke through the corner cells.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Styling 3"

# Pinned for the same reason as styling2.cr: the capture (and any terminal
# this runs on with a modern font) shows the exact eighth steps and sextant
# corner pieces rather than the Unicode tier's coarser fallbacks.
s.glyph_tier = Glyphs::Tier::Extended
# Octant corner pieces (Unicode 16) pinned on, as in styling2.cr.
s.glyph_octants = true

# Neutral backdrop — inner borders show it through the whole border band.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: 0x3a4250)

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Inner block borders — ratio: 1/8 .. 8/8{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

# Same palette as styling2.cr, so the two ladders compare box-for-box.
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
    content: "{center}type: :inner\nratio: #{ratio}\n(#{i + 1}/8 column){/center}", parse_tags: true,
    style: Style.new(fg: "white", bg: bg, border: Border.new(type: :inner, fg: fg, ratio: ratio))
end

s.exec
