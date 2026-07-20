# Example: Crysterm::Widget::Graph::PieChart
#
# Minimal, self-contained example of a single PieChart.
# Run it:     crystal run examples/widget/graph/pie_chart/pie_chart.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("PieChart",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    # Reshuffle the slice proportions per frame (read-only widget, no keys —
    # reach it via the window and reset #slices, guarded by the concrete type);
    # returns to the initial split.
    [
      [50.0, 30.0, 20.0],
      [20.0, 50.0, 30.0],
      [35.0, 15.0, 50.0],
      [50.0, 30.0, 20.0],
    ].each do |vals|
      d.act(dwell: 0.6) do |s|
        s.children.each do |c|
          next unless c.is_a?(GraphPieChart)
          colors = GraphPieChart::DEFAULT_COLORS
          labels = %w[web db cache]
          c.slices = vals.map_with_index do |v, i|
            GraphPieChart::Slice.new(v, colors[i], labels[i])
          end
        end
      end
    end
  }) do |window|
  GraphPieChart.new \
    parent: window, top: "center", left: "center", width: 24, height: 13,
    slices: [
      GraphPieChart::Slice.new(50.0, 0x40E0D0, "web"),
      GraphPieChart::Slice.new(30.0, 0xE0A040, "db"),
      GraphPieChart::Slice.new(20.0, 0xE04060, "cache"),
    ]
end
