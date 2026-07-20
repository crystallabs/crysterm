# Example: Crysterm::Layout::HBox
#
# Minimal, self-contained example of a single HBox.
# Run it:     crystal run examples/layout/hbox/hbox.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

include Crysterm
include Crysterm::Widgets

WidgetExample.run "HBox" do |window|
  window.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = Widget::Box.new \
    parent: window, top: 0, left: 0, width: "100%", height: "100%",
    layout: Layout::HBox.new(spacing: 1)
  # Children given no width share the row equally (align: stretch fills height).
  %w[Left Middle Middle Right].each do |label|
    Widget::Box.new parent: container, content: "{center}#{label}{/center}", parse_tags: true
  end
end
