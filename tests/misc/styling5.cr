# FEATURE: Lights and looks — the scene light driving relief and shadows.
#
# Part of the borders demo set (guide: ../../README-borders.md).
#
# Relief shading and shadow placement are both projections of one fact:
# where the light is. `Window#light` holds the scene default (NW
# directional — the classic hardcoded top-left assumption, made explicit)
# and any widget overrides it with `Style#light`. A `Light` is an 8-way
# direction plus a kind: `Directional` (parallel rays — a widget's cast
# shadow is its exact silhouette) or `Spot` (a point source on the
# direction axis; rays diverge like a cone, so an auto-placed shadow spills
# one cell past its free ends). See plans/BORDERS.md § 4.
#
# Row 1 — the `Style#look` presets under the default NW light: relief
# expressed in color (`:raised`/`:sunken`) and in glyph weight
# (`:beveled`/`:chiseled`, the mixed-weight joins styling.cr used to
# hand-assemble). Row 2 — auto-placed shadows (`shadow: true`) under
# different lights: the classic NW, a N directional (silhouette-exact
# bottom band), the same N as a spot (band spills a cell each side), and a
# SE light (shadow flips to top/left). Row 3 — the composite looks and the
# weight rendition on the other media: `:elevated`, thin `:floating`, the
# dotted weight bevel, and a braille ring one dot-line heavier on its lit
# sides.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Styling 5"

# Extended tier pinned for the braille box (and exact block eighths), as in
# styling2-4.cr.
s.glyph_tier = Glyphs::Tier::Extended

# Neutral backdrop: shadows darken whatever is behind the widget.
Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: 0x3a4250)

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Lights and looks — relief and shadows follow the scene light{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#403040")

COLORS = [
  {0x2050a0, "#9fc7ff"}, {0x146054, "#5fe0c0"}, {0x4a2060, "#d090ff"},
  {0x204020, "#90e070"}, {0x601818, "#ff9090"}, {0x585020, "#e0d878"},
  {0x14505c, "#70cce0"}, {0x50285c, "#cc88e8"}, {0x1c3a5c, "#7fb2e8"},
  {0x355020, "#b0d878"}, {0x5c2038, "#e888ac"}, {0x20504a, "#78d8c4"},
]

# {label, style options} per box; fg/bg step through COLORS in the loop.
boxes = [
  # Row 1: the look presets (scene light: the default NW directional).
  {"look: :raised\n(outset shade)",
   Style.new(border: Border.new(fg: "#9fc7ff"), look: :raised)},
  {"look: :sunken\n(inset shade)",
   Style.new(border: Border.new(fg: "#5fe0c0"), look: :sunken)},
  {"look: :beveled\n(weight bevel)",
   Style.new(border: Border.new(type: :dotted, fg: "#d090ff"), look: :beveled)},
  {"look: :chiseled\n(inset weight)",
   Style.new(border: Border.new(type: :dotted, fg: "#90e070"), look: :chiseled)},
  # Row 2: auto-placed shadows under different lights.
  {"shadow: true\n(scene light NW)",
   Style.new(border: true, shadow: true)},
  {"light: :n\n(exact silhouette)",
   Style.new(border: true, shadow: true, light: :n)},
  {"light: n spot\n(band spills 1)",
   Style.new(border: true, shadow: true, light: Light.new(:n, :spot))},
  {"light: :se\n(shadow flips)",
   Style.new(border: true, shadow: true, light: :se)},
  # Row 3: composites and the weight rendition on the other media.
  {"look: :elevated\n(raised+shadow)",
   Style.new(border: Border.new(fg: "#7fb2e8"), look: :elevated)},
  {"look: :floating\n(thin shadow)",
   Style.new(border: Border.new(type: :rounded, fg: "#b0d878"), look: :floating)},
  {"beveled + :se\n(bevel follows)",
   Style.new(border: Border.new(type: :dotted, fg: "#e888ac"), look: :beveled, light: :se)},
  {"braille weight\n(lit +1 dot-line)",
   Style.new(border: Border.new(type: :braille, fg: "#78d8c4",
     relief: :outset, relief_style: :weight))},
]

boxes.each_with_index do |(label, style), i|
  bg, fg = COLORS[i]
  style.fg = "white"
  style.bg = bg
  style.border.fg = fg if style.border.fg.nil?
  Widget::Box.new \
    parent: s, top: 2 + (i // 4) * 7, left: 2 + (i % 4) * 20, width: 17, height: 5,
    content: "{center}#{label}{/center}", parse_tags: true,
    style: style
end

s.exec
