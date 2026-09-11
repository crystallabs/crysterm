# Example: Crysterm::Layout::Dock
#
# Minimal, self-contained example of a single Dock.
# Run it:     crystal run tests/layout/dock/dock.cr
require "../../widget/example"

alias CT = Crysterm
alias CW = CT::Widgets

CT::WidgetExample.run "Dock" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  # Five children, each docked to an edge (or the center) by a Border::Hint.
  container = CW::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: CT::Layout::Dock.new
  CW::Box.new parent: container, height: 3,
    layout_hint: CT::Layout::Dock::Hint.new(:top),
    content: "{center}Top{/center}", parse_tags: true
  CW::Box.new parent: container, height: 3,
    layout_hint: CT::Layout::Dock::Hint.new(:bottom),
    content: "{center}Bottom{/center}", parse_tags: true
  CW::Box.new parent: container, width: 16,
    layout_hint: CT::Layout::Dock::Hint.new(:left),
    content: "{center}Left{/center}", parse_tags: true
  CW::Box.new parent: container, width: 16,
    layout_hint: CT::Layout::Dock::Hint.new(:right),
    content: "{center}Right{/center}", parse_tags: true
  CW::Box.new parent: container,
    layout_hint: CT::Layout::Dock::Hint.new(:center),
    content: "{center}Center{/center}", parse_tags: true
end
