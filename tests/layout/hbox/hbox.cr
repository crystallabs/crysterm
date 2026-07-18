# Example: Crysterm::Layout::HBox
#
# Minimal, self-contained example of a single HBox.
# Run it:     crystal run examples/layout/hbox/hbox.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

Crysterm::WidgetExample.run "HBox" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = Crysterm::Widget::Box.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    layout: Crysterm::Layout::HBox.new(spacing: 1), overflow: :ignore
  # Children given no width share the row equally (align: stretch fills height).
  %w[Left Middle Middle Right].each do |label|
    Crysterm::Widget::Box.new parent: container, content: "{center}#{label}{/center}", parse_tags: true
  end
end
