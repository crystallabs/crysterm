# Example: Crysterm::Layout::UniformGrid
#
# Minimal, self-contained example of a single UniformGrid.
# Run it:     crystal run examples/layout/uniform_grid/uniform_grid.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

Crysterm::WidgetExample.run "UniformGrid" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = Crysterm::Widget::Box.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    layout: Crysterm::Layout::UniformGrid.new, overflow: :ignore
  8.times do |i|
    Crysterm::Widget::Box.new parent: container, width: 16, height: 5,
      content: "{center}cell #{i + 1}{/center}", parse_tags: true
  end
end
