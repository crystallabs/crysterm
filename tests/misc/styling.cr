# FEATURE: Borders — the highlights.
#
# A curated tour of the border system's best looks, one box per idea. This
# is the summary; the real, structured presentation — the axis model, every
# type, thick bands, separators, light, relief, looks and shadows, with
# text and per-topic demo links — is ../../README-borders.md. The per-group
# demos it links: styling2/3.cr (block thickness ladders), styling4.cr
# (braille across the axes), styling5.cr (lights & looks), styling6.cr
# (thick bands, block patterns, separators), styling7.cr (shadow anatomy).
#
# Every border is a stroke over orthogonal axes — type x pattern x align x
# ratio x corners (+ corner_ratio) — with `type:` presets naming the common
# points; anything unachievable rounds down to the nearest rendition.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Styling"

# Extended tier pinned for the sub-cell boxes (block eighths, braille dots),
# as in styling2-7.cr. Interactively the tier is auto-detected.
s.glyph_tier = Glyphs::Tier::Extended

# Neutral backdrop so transparent grounds and shadows have something to show.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: 0x3a4250)

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Borders — the highlights · full guide: README-borders.md{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

# {bg, border fg} per box, the shared styling2-7.cr palette.
COLORS = [
  {0x2050a0, "#9fc7ff"}, {0x146054, "#5fe0c0"}, {0x4a2060, "#d090ff"},
  {0x204020, "#90e070"}, {0x601818, "#ff9090"}, {0x585020, "#e0d878"},
  {0x14505c, "#70cce0"}, {0x50285c, "#cc88e8"}, {0x1c3a5c, "#7fb2e8"},
  {0x355020, "#b0d878"}, {0x5c2038, "#e888ac"}, {0x20504a, "#78d8c4"},
]

# The tab shape: only the top corners rounded (per-corner treatments).
tab = Border.new
tab.corners = Border::Corners.new(tl: Border::Corner::Rounded, tr: Border::Corner::Rounded)

# Each entry: {style options beyond fg/bg, 1-3 label lines}.
boxes = [
  # Row 1 — line borders: presets and new axis combinations.
  {Style.new(border: Border.new(type: :rounded)), # the arc-corner classic
   "type: :rounded"},
  {Style.new(border: Border.new(pattern: :double)), # the double-line family
   "pattern: :double"},
  {Style.new(border: Border.new(ratio: :full)), # ratio > 1/2 = heavy line
   "ratio: :full\n(heavy)"},
  {Style.new(border: Border.new(pattern: :dashed, corners: :rounded)), # composable axes
   "dashed + rounded"},
  # Row 2 — sub-cell media: block ink and braille dots.
  {Style.new(border: Border.new(type: :outer, ratio: :half)), # rim-flush block ink
   "block :outer\nratio: :half"},
  {Style.new(border: Border.new(type: :inner, ratio: :half)), # content-hugging, transparent ground
   "block :inner\n(floating ring)"},
  {Style.new(border: Border.new(type: :braille)), # dot ring, union corners
   "type: :braille"},
  {Style.new(border: Border.new(type: :outer, ratio: :thin, corner_ratio: :half)), # corner beads
   "corner beads\n(thin + :half)"},
  # Row 3 — composed looks: light-driven relief and shadows.
  {Style.new(border: Border.new(type: :dotted), look: :beveled), # the weight bevel, automatic
   "look: :beveled"},
  {Style.new(border: true, look: :elevated), # raised shading + auto shadow
   "look: :elevated"},
  {Style.new(border: tab), # border-radius: 8px 8px 0 0
   "tab corners\n(tl/tr rounded)"},
  {Style.new(border: Border.new(type: :braille, ratio: :half, corner_ratio: :full)), # braille beads
   "braille + beads"},
]

boxes.each_with_index do |(style, label), i|
  bg, fg = COLORS[i]
  style.fg = "white"
  style.bg = bg
  style.border.fg = fg if style.border.fg.nil?
  Widget::Box.new \
    parent: s, top: 2 + (i // 4) * 7, left: 1 + (i % 4) * 20, width: 18, height: 5,
    content: "{center}#{label}{/center}", parse_tags: true,
    style: style
end

s.exec
