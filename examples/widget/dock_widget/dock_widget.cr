# Example: Crysterm::Widget::DockWidget
#
# Minimal, self-contained example of a single DockWidget.
# Run it:     crystal run examples/widget/dock_widget/dock_widget.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run "DockWidget" do |screen|
  screen.stylesheet = "DockWidget { border: solid; color: #c0caf5; }"
  dock = Crysterm::Widget::DockWidget.new \
    parent: screen, top: 0, left: 0, width: 26, height: "100%",
    title: " Explorer ", area: :left
  Crysterm::Widget::Box.new parent: dock, top: 0, left: 1, content: "src/"
  Crysterm::Widget::Box.new parent: dock, top: 1, left: 2, content: "crysterm.cr"
  Crysterm::Widget::Box.new parent: dock, top: 2, left: 2, content: "widget.cr"
end
