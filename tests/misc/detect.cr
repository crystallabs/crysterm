# FEATURE: Terminal feature auto-detection.
#
# At startup Crysterm probes the terminal — truecolor, Unicode, color count,
# and the best in-band graphics protocol (Kitty → Sixel → iTerm → glyphs →
# ANSI) — and every capability-dependent widget picks its rendering from
# that, with no code changes. Here the SAME `Graph::Donut` widget is shown
# twice: once pinned to Kitty pixel graphics (the pixel ring shows on
# Kitty-capable terminals and in the PNG shot), once to universal braille
# glyphs. The lower panel lists what detection found on THIS terminal, and
# every probed default can be overridden through the config system
# (`--media-backend=`, `--dump-config`, CRYSTERM_* env vars, config file).

require "../../src/crysterm"

include Crysterm
include Crysterm::Widgets

s = Window.new title: "Feature detection"

Widget::Box.new parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Terminal feature auto-detection — one widget, best backend wins{/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202830")

# The same radial gauge twice; only the pinned Media backend differs.
kitty = GraphDonut.new parent: s, top: 2, left: 4, width: 30, height: 13,
  value: 42, label: "KITTY", fill_color: 0xE0A040, show_track: true, track_color: 0x2A3440,
  type: Widget::Media::Type::Kitty,
  style: Style.new(fg: "white", bg: "#101820", border: true)

braille = GraphDonut.new parent: s, top: 2, left: 46, width: 30, height: 13,
  value: 68, label: "BRAILLE", fill_color: 0x40E0D0, show_track: true, track_color: 0x2A3440,
  type: Widget::Media::Type::GlyphBraille,
  style: Style.new(fg: "white", bg: "#101820", border: true)

Widget::Box.new parent: s, top: 15, left: 4, width: 30, height: 1, parse_tags: true,
  content: "{center}Forced: kitty pixels{/center}", style: Style.new(fg: "#e0a040")
Widget::Box.new parent: s, top: 15, left: 46, width: 30, height: 1, parse_tags: true,
  content: "{center}Forced: glyph braille{/center}", style: Style.new(fg: "#40e0d0")

# What auto-detection actually found on the terminal running this demo.
feat = s.tput.features
emu = s.tput.emulator
best = Widget::Media.resolve(Widget::Media::Content::Painter, s.tput)
cellpx = s.screen.cell_pixel_width > 0 ? "#{s.screen.cell_pixel_width}×#{s.screen.cell_pixel_height}px" : "n/a"
n_opts = 0
Config.each { n_opts += 1 }

Widget::Box.new parent: s, top: 17, left: 2, width: 76, height: 7,
  label: " Auto-detected on this terminal ", parse_tags: true,
  style: Style.new(border: true, fg: "#c0caf5", bg: "#10141c"),
  content: "\n Truecolor: {bold}#{feat.truecolor?}{/bold}      Unicode: {bold}#{feat.unicode?}{/bold}      " \
           "Colors: {bold}#{feat.number_of_colors}{/bold}      Cell: {bold}#{cellpx}{/bold}\n" \
           " Best graphics: {bold}#{emu.best_graphics}{/bold}      Auto-picked painter backend: {bold}#{best}{/bold}\n\n" \
           "{center}Overridable via #{n_opts} config settings — --media-backend=…, --dump-config{/center}"

phase = 0.5
s.every(0.05.seconds) do
  braille.value = (Math.sin(phase) * 0.5 + 0.5) * 100
  kitty.value = (Math.cos(phase * 0.8) * 0.5 + 0.5) * 100
  phase += 0.03
end

s.exec
