# Example: Crysterm::Widget::Graph::LineChart
#
# Minimal, self-contained example of a single LineChart.
# Run it:     crystal run examples/widget/graph/line_chart/line_chart.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run "LineChart" do |screen|
  screen.stylesheet = "LineChart { border: solid; color: #c0caf5; }"
  chart = Crysterm::Widget::Graph::LineChart.new parent: screen, top: 0, left: 0, width: "100%", height: "100%", title: "Signals"
  chart.add_line "sin", (0..160).map { |i| {i / 20.0, Math.sin(i / 20.0)} }
  chart.add_line "cos", (0..160).map { |i| {i / 20.0, Math.cos(i / 20.0) * 0.6} }
end
