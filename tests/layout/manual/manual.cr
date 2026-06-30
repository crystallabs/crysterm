# Example: Crysterm::Layout::Manual
#
# Minimal, self-contained example of a single Manual.
# Run it:     crystal run examples/layout/manual/manual.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

Crysterm::WidgetExample.run "Manual" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; }"
  # Manual placement: children position themselves by top/left/right/bottom.
  container = Crysterm::Widget::Box.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    layout: Crysterm::Layout::Manual.new, overflow: :ignore
  Crysterm::Widget::Box.new parent: container, top: 1, left: 2, width: 24, height: 4,
    content: "{center}(left: 2, top: 1){/center}", parse_tags: true
  Crysterm::Widget::Box.new parent: container, top: 7, left: 28, width: 26, height: 5,
    content: "{center}(left: 28, top: 7){/center}", parse_tags: true
  Crysterm::Widget::Box.new parent: container, bottom: 1, right: 2, width: 22, height: 4,
    content: "{center}bottom-right{/center}", parse_tags: true
end
