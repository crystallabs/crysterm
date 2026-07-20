# Example: Crysterm::Layout::VBox
#
# Minimal, self-contained example of a single VBox.
# Run it:     crystal run examples/layout/vbox/vbox.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run "VBox" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = Widget::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: Layout::VBox.new(spacing: 1)
  %w[Top Middle Middle Bottom].each do |label|
    Widget::Box.new parent: container, content: "{center}#{label}{/center}", parse_tags: true
  end
end
