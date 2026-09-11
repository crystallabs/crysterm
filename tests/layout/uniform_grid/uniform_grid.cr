# Example: Crysterm::Layout::UniformGrid
#
# Minimal, self-contained example of a single UniformGrid.
# Run it:     crystal run tests/layout/uniform_grid/uniform_grid.cr
require "../../widget/example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "UniformGrid" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = CW::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: CT::Layout::UniformGrid.new
  8.times do |i|
    CW::Box.new parent: container, width: 16, height: 5,
      content: "{center}cell #{i + 1}{/center}", parse_tags: true
  end
end
