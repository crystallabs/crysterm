# Example: Crysterm::Widget::Graph::HeatMap
#
# Minimal, self-contained example of a single HeatMap.
# Run it:     crystal run examples/widget/graph/heatmap/heatmap.cr
# Maintained by tools/manage-examples.cr
require "../../example"

Crysterm::WidgetExample.run("HeatMap",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    # Roll the matrix values each frame (read-only widget, no keys — reach it
    # via the screen and reset #values, guarded by the concrete type), so the
    # colors sweep across the colormap and settle back.
    [0.0, 2.0, 4.0, 0.0].each do |phase|
      d.act(dwell: 0.6) do |s|
        s.children.each do |c|
          next unless c.is_a?(Crysterm::Widget::Graph::HeatMap)
          c.values = (0...5).map do |r|
            (0...8).map { |col| Math.sin((r + col + phase) * 0.5) }
          end
        end
      end
    end
  }) do |screen|
  Crysterm::Widget::Graph::HeatMap.new \
    parent: screen, top: "center", left: "center", width: 34, height: 14,
    colormap: :viridis,
    col_labels: %w[a b c d e f g h],
    row_labels: %w[r0 r1 r2 r3 r4],
    values: (0...5).map { |r| (0...8).map { |c| Math.sin((r + c) * 0.5) } }
end
