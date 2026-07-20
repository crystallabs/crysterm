# Example: Crysterm::Widget::Graph::Bar
#
# Minimal, self-contained example of a single Bar.
# Run it:     crystal run examples/widget/graph/bar/bar.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Bar" do |window|
  window.stylesheet = "Bar { border: solid; color: #7aa2f7; }"
  GraphBar.new \
    parent: window, top: "center", left: "center", width: 44, height: 12,
    values: [3.0, 7.0, 4.0, 9.0, 6.0, 8.0, 2.0, 5.0], labels: %w[Mon Tue Wed Thu Fri Sat Sun Avg],
    bar_width: 3, bar_spacing: 2, show_values: true
end
