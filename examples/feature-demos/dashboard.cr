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
labels = [{"CPU", "#50e0a0"}, {"MEM", "#e0c050"}, {"NET", "#5090e0"}, {"DISK", "#e07050"}]
labels.each_with_index do |(name, color), i|
  Widget::Box.new parent: s, top: 3 + i, left: 2, width: 6, height: 1, content: name,
    style: Style.new(fg: "white", bg: "#0c1014")
  pb = Widget::ProgressBar.new \
    parent: s, top: 3 + i, left: 9, width: 29, height: 1,
    filled: rand(20..80), style: Style.new(fg: color, bg: "#283038")
  gauges << {name, pb, rand(40..70)}
end

# --- Right: process table --------------------------------------------------
table = Widget::Table.new \
  parent: s, top: 1, left: 41, width: 38, height: 9,
  rows: [
    ["PID", "COMMAND", "CPU%", "MEM"],
    ["1042", "crysterm", "12.4", "48M"],
    ["337", "render-fiber", "6.1", "12M"],
    ["891", "event-loop", "2.3", "8M"],
    ["12", "gpm", "0.1", "1M"],
    ["7", "input", "0.4", "2M"],
  ],
  style: Style.new(fg: "white", bg: "#0c1014", border: true)

# --- Bottom: scrolling activity log ----------------------------------------
log = Widget::Box.new \
  parent: s, top: 10, left: 0, width: 79, height: 5,
  content: " Activity", scrollable: true,
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
loglines = [] of String

i = 0
s.every(0.18.seconds) do
  # gauges random-walk toward a moving target
  gauges.each do |(_, pb, _)|
    delta = rand(-6..7)
    pb.filled = (pb.filled + delta).clamp(2, 100)
  end
  if i % 2 == 0
    loglines << "  #{events.sample}"
    loglines.shift if loglines.size > (log.aheight - 2)
    log.content = " Activity\n" + loglines.join("\n")
  end
  i += 1
end

s.exec
