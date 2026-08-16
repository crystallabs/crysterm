# FEATURE: border docking with color blending.
#
# With `Window#border_junctions = true`, borders that touch or overlap are
# re-evaluated into shared junction glyphs (├ ┬ ┼ ┤ ┴ …) instead of visibly
# colliding. When the adjacent borders have different colors,
# `Window#junction_contrast` decides the outcome: Blend mixes the two colors at
# the junction cell, Ignore docks and keeps each cell's own color, and Skip
# leaves differing-color borders undocked. A timer cycles the three modes
# while a box slides into a static one and docks on contact.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Border docking"
s.border_junctions = true
s.junction_contrast = JunctionContrast::Blend

# Backdrop and caption strip.
Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: Style.new(bg: "#1a1b26")
Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Border docking — touching borders merge into shared junction glyphs{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

# Live mode indicator, updated by the mode-cycling timer below.
mode_box = Widget::Box.new parent: s, top: 2, left: 0, width: "100%", height: 1,
  content: "{center}window.junction_contrast = {bold}Blend{/bold} — junction cells blend the two border colors{/center}",
  parse_tags: true, style: Style.new(fg: "#c0caf5", bg: "#1a1b26")

# The three contrast policies, next to the grid that demonstrates them.
Widget::Box.new parent: s, top: 4, left: 2, width: 36, height: 11,
  label: " JunctionContrast ", parse_tags: true,
  content: "\n{#7dcfff-fg}Blend{/#7dcfff-fg}  — junction cells mix the\n" \
           "          two border colors\n\n" \
           "{#e0af68-fg}Ignore{/#e0af68-fg} — dock; each cell keeps\n" \
           "          its own color\n\n" \
           "{#f7768e-fg}Skip{/#f7768e-fg}   — differing colors\n" \
           "          don't dock at all",
  style: Style.new(fg: "#a9b1d6", bg: "#24283b", border: Border.new(fg: "#3b4261"))

# A 2x2 grid of boxes sharing border rows/columns: their meeting points
# resolve to ┬ ├ ┼ ┤ ┴ junctions. Four different border colors, so the
# junction cells are exactly where `junction_contrast` matters.
grid = [
  {4, 42, 18, 6, "#7aa2f7"},
  {4, 59, 19, 6, "#e0af68"},
  {9, 42, 18, 6, "#9ece6a"},
  {9, 59, 19, 6, "#f7768e"},
]
grid.each do |(top, left, width, height, color)|
  Widget::Box.new parent: s, top: top, left: left, width: width, height: height,
    content: "{center}#{color}{/center}", parse_tags: true,
    style: Style.new(fg: "#565f89", bg: "#1f2335", border: Border.new(fg: color))
end

# The docking target: a static box near the right edge …
Widget::Box.new parent: s, top: 16, left: 56, width: 22, height: 7,
  content: "{center}static{/center}", parse_tags: true,
  style: Style.new(fg: "#565f89", bg: "#1f2335", border: Border.new(fg: "#7dcfff"))

# … and the slider: it glides right until its border overlaps the target's
# and docks (shared edge becomes ┬/┴ junctions), pauses, and swings back.
slider = Widget::Box.new parent: s, top: 16, left: 37, width: 20, height: 7,
  content: "{center}sliding …{/center}", parse_tags: true,
  style: Style.new(fg: "#c0caf5", bg: "#292e42", border: Border.new(fg: "#bb9af7"))

# The three contrast policies, cycled so the same junctions show them all.
modes = [
  {JunctionContrast::Blend, "junction cells blend the two border colors"},
  {JunctionContrast::Ignore, "junctions form; each cell keeps its own color"},
  {JunctionContrast::Skip, "borders with differing colors stay undocked"},
]
set_mode = ->(i : Int32) do
  mode, desc = modes[i]
  s.junction_contrast = mode
  mode_box.content = "{center}window.junction_contrast = {bold}#{mode}{/bold} — #{desc}{/center}"
end

# One master clock drives both the slider and the contrast mode, everything
# keyed off a tick counter mod 50: the whole scene is a 5.0 s cycle — exactly
# the length of the looping capture — that ends in the state it started in
# (slider docked, Blend mode), so the recording wraps seamlessly whatever its
# start phase. The wrap itself lands inside the docked hold (calm identical
# frames on both sides of the seam).
x = 37 # right border column 56 = docked onto the target's left border
tick = 0
s.every(0.1.seconds) do
  t = tick % 50
  tick += 1

  # Contrast mode: three eras per cycle, wrapping back to Blend at t=0.
  case t
  when  0 then set_mode.call 0
  when 17 then set_mode.call 1
  when 34 then set_mode.call 2
  end

  # Slider: hold docked (0-4), glide out to column 17 (5-24), glide back and
  # re-dock (25-44), hold docked again (45-49) — the two holds join across
  # the wrap into one continuous pause.
  nx = case t
       when 5..24  then 37 - (t - 4)  # 36 down to 17
       when 25..44 then 17 + (t - 24) # 18 back up to 37
       else             x
       end
  if nx != x
    slider.clear_last_rendered_position
    x = nx
    slider.left = x
  end
end

s.exec
