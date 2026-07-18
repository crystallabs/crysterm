# Example: Crysterm::Layout::Grid
#
# Minimal, self-contained example of a single Grid.
# Run it:     crystal run examples/layout/grid/grid.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

Crysterm::WidgetExample.run "Grid" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; }"
  # A 3-column grid; the six children auto-flow row-major into the cells.
  container = Crysterm::Widget::Box.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    layout: Crysterm::Layout::Grid.new(columns: 3, spacing: 1), overflow: :ignore
  6.times do |i|
    Crysterm::Widget::Box.new parent: container,
      content: "{center}r#{i // 3} · c#{i % 3}{/center}", parse_tags: true
  end
end
