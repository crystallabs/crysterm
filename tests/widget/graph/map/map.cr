# Example: Crysterm::Widget::Graph::Map
#
# Minimal, self-contained example of a single Map.
# Run it:     crystal run examples/widget/graph/map/map.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Map" do |window|
  window.stylesheet = "Map { border: solid; }"
  map = GraphMap.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
  map.add_marker 40.7, -74.0, '*', 0xE05050, "NYC"
  map.add_marker 51.5, -0.12, '*', 0x40E0D0, "London"
  map.add_marker 35.7, 139.7, '*', 0xE0A040, "Tokyo"
  map.add_marker(-33.9, 151.2, '*', 0x60C040, "Sydney")
end
