# Example: Crysterm::Layout::VBox
#
# Minimal, self-contained example of a single VBox.
# Run it:     crystal run examples/layout/vbox/vbox.cr
# Maintained by tools/manage-examples.cr
require "../../widget/example"

Crysterm::WidgetExample.run "VBox" do |screen|
  screen.stylesheet = "Box { border: solid; color: #c0caf5; }"
  container = Crysterm::Widget::Box.new \
    parent: screen, top: 0, left: 0, width: "100%", height: "100%",
    layout: Crysterm::Layout::VBox.new(spacing: 1), overflow: :ignore
  %w[Top Middle Middle Bottom].each do |label|
    Crysterm::Widget::Box.new parent: container, content: "{center}#{label}{/center}", parse_tags: true
  end
end
