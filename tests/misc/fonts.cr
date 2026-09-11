# FEATURE: loadable bitmap fonts.
#
# `Crysterm::BitmapFont` loads two on-disk font formats: ttystudio `.json`
# (per-glyph pixel maps) and GNU Unifont `.hex` (~100k glyphs, decoded
# lazily). `Widget::BigText` renders text with any such face via its
# `font:` / `font_bold:` path parameters — here the same specimen is drawn
# with the two bundled Terminus weights and with GNU Unifont, each panel
# labeled with the font file it loads.

require "../../src/crysterm"

alias CT = Crysterm
alias CW = CT::Widgets

FONT_DIR = Path[__DIR__, "..", "..", "data", "font"].normalize

s = CT::Window.new title: "Bitmap fonts"

# Backdrop and caption strip.
CW::Box.new parent: s, top: 0, left: 0, width: "100%", height: "100%",
  style: CT::Style.new(bg: "#1a1b26")
CW::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Loadable bitmap fonts — ttystudio {open}.json{close} and GNU Unifont {open}.hex{close}{/center}",
  parse_tags: true, style: CT::Style.new(fg: "white", bg: "#202830")

# One panel per font face: the border label is the file the face loads from.
faces = [
  {"ter-u14n.json", "#7dcfff", "Terminus, normal"},
  {"ter-u14b.json", "#f7768e", "Terminus, bold"},
  {"unifont.hex", "#9ece6a", "GNU Unifont"},
]

borders = [] of CT::Border
faces.each_with_index do |(file, color, desc), i|
  border = CT::Border.new fg: "#3b4261"
  borders << border
  panel = CW::Box.new parent: s, top: 3, left: 1 + i * 26, width: 25, height: 19,
    label: " #{file} ", style: CT::Style.new(bg: "#24283b", border: border)

  # The specimen: `font:` points BigText at the face to load. `BitmapFont`
  # picks the parser by extension, so `.json` and `.hex` both load here.
  CW::BigText.new parent: panel, top: "center", left: "center",
    content: "Aa", font: (FONT_DIR / file).to_s,
    style: CT::Style.new(fg: color, bg: "#24283b")

  CW::Box.new parent: panel, bottom: 0, left: 0, width: "100%-2", height: 1,
    content: "{center}#{desc}{/center}", parse_tags: true,
    style: CT::Style.new(fg: "#565f89", bg: "#24283b")
end

CW::Box.new parent: s, top: 23, left: 0, width: "100%", height: 1,
  content: "{center}BitmapFont.load picks the format by extension; .hex glyphs decode on first use{/center}",
  parse_tags: true, style: CT::Style.new(fg: "#565f89", bg: "#1a1b26")

# Gentle accent: the highlight ring wanders across the three panels.
active = 0
s.every(1.2.seconds) do
  borders.each_with_index { |b, i| b.fg = i == active ? faces[i][1] : "#3b4261" }
  active = (active + 1) % borders.size
end

s.exec
