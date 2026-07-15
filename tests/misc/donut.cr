# IMPRESSIVE DEMO: ring donuts + a gauge list.
#
# `Widget::Graph::Donut` is a radial percentage indicator (drawn on a
# backend-agnostic Canvas); `Widget::GaugeList` stacks labeled horizontal
# gauges. Press q / Ctrl+C to quit.

require "../../src/crysterm"

include Crysterm

s = Window.new title: "Donut + GaugeList"

# Mode 1 (default): only the filled arc is drawn — the remainder stays empty.
cpu = Widget::Graph::Donut.new parent: s, top: 0, left: 0, width: 20, height: 11,
  value: 0, label: "CPU", fill_color: 0x40E0D0, style: Style.new(fg: "white", bg: "#101820", border: true)
# Mode 2 (show_track): the full ring shows in the track color, value arc on top.
mem = Widget::Graph::Donut.new parent: s, top: 0, left: 21, width: 20, height: 11,
  value: 0, label: "MEM", fill_color: 0xE0A040, show_track: true, track_color: 0x404850,
  style: Style.new(fg: "white", bg: "#101820", border: true)

gl = Widget::GaugeList.new parent: s, top: 0, left: 42, width: 34, height: 11,
  style: Style.new(fg: "white", bg: "#101820", border: true)
%w[disk net gpu pwr swap io].each { |n| gl.add_item n, 0 }

# FPS overlay (bottom-left): with the 60 fps cap, driving updates at ~60 Hz
# shows the counter climbing toward 60.
Widget::Fps.new parent: s, top: "100%-1", left: 0,
  format: "FPS %5s  (R %5s / D %5s)", args: [:fps, :render, :draw],
  style: Style.new(fg: "black", bg: 0x40e0c0)

# Drive at ~60 Hz with a small per-frame step, so the animation stays smooth and
# slow while the render loop runs at the new cap.
phase = 0.0
s.every((1/60).seconds) do
  cpu.value = (Math.sin(phase) * 0.5 + 0.5) * 100
  mem.value = (Math.cos(phase * 0.7) * 0.5 + 0.5) * 100
  gl.gauges.each_with_index { |g, i| gl[i] = (Math.sin(phase + i) * 0.5 + 0.5) * 100 }
  phase += 0.025
end

s.exec
