# IMPRESSIVE DEMO: a live "system monitor" dashboard.
#
# Pulls several widgets together into one screen — labeled gauges (progress
# bars), a data table, and a scrolling activity log — all updating live, the way
# a real TUI app composes a UI.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Dashboard"
s.show_fps = nil

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Crysterm Dashboard — live system monitor{/center}", parse_tags: true,
  style: Style.new(fg: "white", bg: "#283048")

# --- Left: resource gauges -------------------------------------------------
Widget::Box.new \
  parent: s, top: 1, left: 0, width: 40, height: 9,
  content: " Resources", style: Style.new(fg: "cyan", bg: "#0c1014", border: true)

gauges = [] of {String, Widget::ProgressBar, Int32}
labels = [{"CPU", 0x50e0a0}, {"MEM", 0xe0c050}, {"NET", 0x5090e0}, {"DISK", 0xe07050}]
labels.each_with_index do |(name, color), i|
  Widget::Box.new parent: s, top: 3 + i, left: 2, width: 6, height: 1, content: name,
    style: Style.new(fg: "white", bg: "#0c1014")
  pb = Widget::ProgressBar.new \
    parent: s, top: 3 + i, left: 9, width: 29, height: 1,
    filled: rand(20..80), style: Style.new(fg: color, bg: 0x283038)
  gauges << {name, pb, rand(40..70)}
end

# --- Right: process table --------------------------------------------------
# A `Table` double-spaces its rows (a rule between each), so N rows need
# 2N+1 grid rows; header + 3 rows fills this height-9 box exactly.
table = Widget::Table.new \
  parent: s, top: 1, left: 41, width: 38, height: 9,
  rows: [
    ["PID", "COMMAND", "CPU%", "MEM"],
    ["1042", "crysterm", "12.4", "48M"],
    ["337", "render-fiber", "6.1", "12M"],
    ["891", "event-loop", "2.3", "8M"],
  ],
  style: Style.new(fg: "white", bg: "#0c1014", border: true)

# --- Bottom: scrolling activity log ----------------------------------------
# `Widget::Log` is a scrollable text box you append lines to: `add` scrolls the
# newest into view and drops the oldest past `scrollback`. The title lives in the
# border label, not the scroll region.
log = Widget::Log.new \
  parent: s, top: 10, left: 0, width: 79, height: 5,
  label: " Activity ", scrollback: 100,
  style: Style.new(fg: "#a0e0a0", bg: "black", border: true)

events = [
  "render frame committed (diff: 14 cells)",
  "fiber A yielded, fiber B resumed",
  "mouse: xterm move @ 42,7",
  "widget 'table' attached",
  "GC: heap 4.2M / 6.0M",
  "key event dispatched to focused widget",
  "mouse: gpm click @ 8,11",
  "progressbar 'CPU' updated -> 63%",
]

i = 0
s.every(0.18.seconds) do
  # gauges random-walk toward a moving target
  gauges.each do |(_, pb, _)|
    delta = rand(-6..7)
    pb.filled = (pb.filled + delta).clamp(2, 100)
  end
  log.add events.sample if i % 2 == 0
  i += 1
end

s.exec
