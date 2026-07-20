# Example: Crysterm::Widget::Tree
#
# Minimal, self-contained example of a single Tree.
# Run it:     crystal run examples/widget/tree/tree.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("Tree",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :down, times: 4, dwell: 0.35
    d.key :up, times: 4, dwell: 0.35
  }) do |window|
  window.stylesheet = "Tree { border: solid; color: #c0caf5; }"
  tree = Tree.new parent: window, top: "center", left: "center", width: 34, height: 12, label: " Project "
  src = tree.add "src"
  src.add "crysterm.cr"
  src.add "widget.cr"
  docs = tree.add "docs"
  docs.add "README.md"
  docs.add "USAGE.md"
  tree.add "shard.yml"
  tree.expand_all
  tree.focus
end
