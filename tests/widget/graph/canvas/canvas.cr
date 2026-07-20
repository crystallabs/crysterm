# Example: Crysterm::Widget::Graph::Canvas
#
# Minimal, self-contained example of a single Canvas.
# Run it:     crystal run examples/widget/graph/canvas/canvas.cr
# Maintained by tools/manage-examples.cr
require "../../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "Canvas" do |window|
  window.stylesheet = "Canvas { border: solid; }"
  GraphCanvas.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    content: "{center}Canvas{/center}", parse_tags: true
end
