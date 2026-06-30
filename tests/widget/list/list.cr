# Example: Crysterm::Widget::List
#
# Minimal, self-contained example of a single List.
# Run it:     crystal run examples/widget/list/list.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("List",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :down, times: 4, dwell: 0.4
    d.key :up, times: 2, dwell: 0.4
    d.key :end, dwell: 0.6
    d.key :home, dwell: 0.6
  }) do |screen|
  screen.stylesheet = "List { border: solid; color: #c0caf5; }"
  list = Crysterm::Widget::List.new \
    parent: screen, top: "center", left: "center", width: 28, height: 9,
    items: %w[Alpha Beta Gamma Delta Epsilon]
  list.focus
end
