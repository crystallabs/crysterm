# Example: Crysterm::Layout::Grid
#
# Minimal, self-contained example of a single Grid.
# Run it:     crystal run tests/layout/grid/grid.cr
require "../../widget/example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "Grid" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  # A 3-column grid; the six children auto-flow row-major into the cells.
  container = CW::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: CT::Layout::Grid.new(columns: 3, spacing: 1)
  6.times do |i|
    CW::Box.new parent: container,
      content: "{center}r#{i // 3} · c#{i % 3}{/center}", parse_tags: true
  end
end
