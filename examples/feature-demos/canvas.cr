# IMPRESSIVE DEMO: the backend-agnostic vector Canvas.
#
# `Widget::Graph::Canvas` draws with a `QPainter`-style `Painter` and presents
# the result through whatever image backend the terminal supports — Kitty/Sixel
# graphics where available, else sub-cell Unicode glyphs (braille by default).
# The *same* paint code below renders identically on every terminal.
#
# Press `q` / Ctrl+C to quit.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "Canvas"

Widget::Box.new \
  parent: s, top: 0, left: 0, width: "100%", height: 1,
  content: "{center}Vector Canvas — auto-detected backend (braille fallback){/center}",
  parse_tags: true, style: Style.new(fg: "white", bg: "#202838")

# A live waveform plot. Logical coordinate space is x∈0..2π, y∈-1.2..1.2, so the
# paint code is resolution-independent — Canvas maps it to the backend's pixels.
wave = Widget::Graph::Canvas.new \
  parent: s, top: 2, left: 1, width: 76, height: 18,
  label: " sin / cos ", style: Style.new(fg: "cyan", bg: "#101820", border: true)

phase = 0.0
wave.on_paint do |p|
  w = wave.device.native_resolution(74, 16)[0] # interior cells → device px
  p.set_window 0.0, -1.2, Math::PI * 2, 2.4

  # Zero axis.
  p.pen = 0x303840
  p.draw_line 0.0, 0.0, Math::PI * 2, 0.0

  # Two phase-shifted traces.
  steps = w
  p.pen = 0x40E0D0
  p.draw_polyline(Array.new(steps + 1) { |i|
    x = i * Math::PI * 2 / steps
    {x, Math.sin(x + phase)}
  })
  p.pen = 0xE0A040
  p.draw_polyline(Array.new(steps + 1) { |i|
    x = i * Math::PI * 2 / steps
    {x, Math.cos(x * 2 + phase) * 0.6}
  })
end

s.every(0.08.seconds) do
  phase += 0.2
  wave.refresh
end

s.exec
