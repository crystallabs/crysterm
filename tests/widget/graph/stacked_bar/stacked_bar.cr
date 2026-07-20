# Example: Crysterm::Widget::Graph::StackedBar
#
# Minimal, self-contained example of a single StackedBar.
# Run it:     crystal run examples/widget/graph/stacked_bar/stacked_bar.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("StackedBar",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    # Distinct proportions per frame (uniform scaling would leave the
    # auto-scaled chart unchanged); returns to the initial set.
    [
      [[3.0, 2.0, 1.0], [2.0, 4.0, 2.0], [1.0, 3.0, 4.0], [4.0, 1.0, 2.0]],
      [[5.0, 1.0, 2.0], [1.0, 2.0, 5.0], [3.0, 3.0, 2.0], [2.0, 5.0, 1.0]],
      [[1.0, 4.0, 4.0], [5.0, 1.0, 1.0], [2.0, 2.0, 5.0], [4.0, 4.0, 1.0]],
      [[3.0, 2.0, 1.0], [2.0, 4.0, 2.0], [1.0, 3.0, 4.0], [4.0, 1.0, 2.0]],
    ].each do |vals|
      d.act(dwell: 0.6) { |s| s.children.each { |c| c.values = vals if c.is_a?(GraphStackedBar) } }
    end
  }) do |window|
  window.stylesheet = "StackedBar { border: solid; color: #c0caf5; }"
  GraphStackedBar.new \
    parent: window, top: "center", left: "center", width: 46, height: 12,
    values: [[3.0, 2.0, 1.0], [2.0, 4.0, 2.0], [1.0, 3.0, 4.0], [4.0, 1.0, 2.0]],
    labels: %w[Q1 Q2 Q3 Q4], bar_width: 4, bar_spacing: 3
end
