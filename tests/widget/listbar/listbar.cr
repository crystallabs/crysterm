# Example: Crysterm::Widget::ListBar
#
# Minimal, self-contained example of a single ListBar.
# Run it:     crystal run examples/widget/listbar/listbar.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("ListBar",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :right, times: 4, dwell: 0.35
    d.key :left, times: 4, dwell: 0.35
  }) do |window|
  window.stylesheet = "ListBar { color: #c0caf5; }"
  lb = ListBar.new parent: window, top: "center", left: 0, width: "100%", height: 1, mouse: true
  lb.items = ["File", "Edit", "View", "Tools", "Help"]
  lb.focus
end
