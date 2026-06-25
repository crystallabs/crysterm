# IMPRESSIVE DEMO: a Qt-Charts-style line chart.
#
# `Widget::Graph::LineChart` draws its plot on a backend-agnostic `Canvas`
# (sixel/kitty where available, else braille) while the title, value axes and
# legend are crisp terminal text. Modeled after Qt's QChart/QLineSeries.
#
# Press `q` / Ctrl+C to quit.

require "../../src/crysterm"

include Crysterm

s = Screen.new title: "LineChart"

chart = Widget::Graph::LineChart.new \
  parent: s, top: 1, left: 1, width: "100%-2", height: "100%-2",
  title: "Live signals", style: Style.new(fg: "white", bg: "#101820", border: true)

chart.axis_y.minimum = -1.2
chart.axis_y.maximum = 1.2
chart.axis_x.title = "t"

phase = 0.0
s.every(0.08.seconds) do
  chart.clear_series
  chart.add_line "sin", (0..160).map { |i| {i / 20.0, Math.sin(i / 20.0 + phase)} }
  chart.add_line "cos·½", (0..160).map { |i| {i / 20.0, Math.cos(i / 20.0 * 2 + phase) * 0.6} }
  chart.refresh
  phase += 0.2
end

s.exec
