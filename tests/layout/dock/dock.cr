# Example: Crysterm::Layout::Dock
#
# Minimal, self-contained example of a single Dock.
# Run it:     crystal run tests/layout/dock/dock.cr
require "../../widget/example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run "Dock" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  # Five children, each docked to an edge (or the center) by a Border::Hint.
  container = Widget::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: Layout::Dock.new
  Widget::Box.new parent: container, height: 3,
    layout_hint: Layout::Dock::Hint.new(:top),
    content: "{center}Top{/center}", parse_tags: true
  Widget::Box.new parent: container, height: 3,
    layout_hint: Layout::Dock::Hint.new(:bottom),
    content: "{center}Bottom{/center}", parse_tags: true
  Widget::Box.new parent: container, width: 16,
    layout_hint: Layout::Dock::Hint.new(:left),
    content: "{center}Left{/center}", parse_tags: true
  Widget::Box.new parent: container, width: 16,
    layout_hint: Layout::Dock::Hint.new(:right),
    content: "{center}Right{/center}", parse_tags: true
  Widget::Box.new parent: container,
    layout_hint: Layout::Dock::Hint.new(:center),
    content: "{center}Center{/center}", parse_tags: true
end
