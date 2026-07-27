# Example: Crysterm::Widget::GroupBox
#
# Minimal, self-contained example of a single GroupBox.
# Run it:     crystal run examples/widget/group_box/group_box.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "GroupBox" do |screen|
  screen.stylesheet = "GroupBox { border: solid; color: #c0caf5; }"
  gb = Crysterm::Widget::GroupBox.new parent: screen, top: "center", left: "center", width: 40, height: 8, title: " Connection "
  Crysterm::Widget::Box.new parent: gb, top: 1, left: 2, content: "Host: localhost"
  Crysterm::Widget::Box.new parent: gb, top: 2, left: 2, content: "Port: 5432"
  Crysterm::Widget::Box.new parent: gb, top: 3, left: 2, content: "SSL:  enabled"
end
