# FEATURE: no ncurses dependency — capability detection via tput.cr.
#
# Crysterm talks to the terminal directly through the `tput.cr` shard. It reads
# capabilities from a terminfo database (via `unibilium`) when available, and
# otherwise falls back to built-in escape sequences. The detected capabilities
# below are what drive rendering decisions (unicode, truecolor, color depth).

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Terminfo"
s.show_fps = nil

f = s.tput.features
backend = s.tput.terminfo ? "unibilium terminfo database" : "built-in sequences"

rows = [
  {"Terminal ($TERM)", ENV["TERM"]? || "unknown"},
  {"Capability backend", backend},
  {"Unicode", f.unicode? ? "yes" : "no"},
  {"TrueColor (24-bit)", f.truecolor? ? "yes" : "no"},
  {"Color", f.color? ? "yes" : "no"},
  {"Number of colors", f.number_of_colors.to_s},
  {"Broken ACS", f.broken_acs? ? "yes" : "no"},
]

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Terminal capabilities (no ncurses){/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#103030")

box = Widget::Box.new \
  parent: s, top: 2, left: 8, width: 64, height: 12,
  content: "",
  style: Style.new(fg: "green", bg: "#101418", border: true)

body = rows.map { |(k, v)| "  #{k.ljust(22)} : #{v}" }.join("\n")
box.content = body

# A small blinking accent so the recording isn't fully static.
dot = Widget::Box.new \
  parent: s, top: 2, left: 70, width: 3, height: 1,
  content: "*", style: Style.new(fg: "yellow")

on = true
s.every(0.4.seconds) do
  dot.content = on ? "*" : " "
  on = !on
end

s.exec
