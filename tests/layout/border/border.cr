# Example: Crysterm::Layout::Border
#
# Minimal, self-contained example of a single Border.
# Run it:     crystal run examples/layout/border/border.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run "Border" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  # Five children, each docked to an edge (or the center) by a Border::Hint.
  container = Widget::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: Layout::Border.new
  Widget::Box.new parent: container, height: 3,
    layout_hint: Layout::Border::Hint.new(:top),
    content: "{center}Top{/center}", parse_tags: true
  Widget::Box.new parent: container, height: 3,
    layout_hint: Layout::Border::Hint.new(:bottom),
    content: "{center}Bottom{/center}", parse_tags: true
  Widget::Box.new parent: container, width: 16,
    layout_hint: Layout::Border::Hint.new(:left),
    content: "{center}Left{/center}", parse_tags: true
  Widget::Box.new parent: container, width: 16,
    layout_hint: Layout::Border::Hint.new(:right),
    content: "{center}Right{/center}", parse_tags: true
  Widget::Box.new parent: container,
    layout_hint: Layout::Border::Hint.new(:center),
    content: "{center}Center{/center}", parse_tags: true
end
