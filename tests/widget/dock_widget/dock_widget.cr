# Example: Crysterm::Widget::DockWidget
#
# Minimal, self-contained example of a single DockWidget.
# Run it:     crystal run tests/widget/dock_widget/dock_widget.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "DockWidget" do |window|
  window.stylesheet = "DockWidget { border: solid; color: #c0caf5; }"
  dock = CW::DockWidget.new \
    parent: window, top: 0, left: 0, width: 26, height: "100%",
    title: " Explorer ", area: :left
  CW::Box.new parent: dock, top: 0, left: 1, content: "src/"
  CW::Box.new parent: dock, top: 1, left: 2, content: "crysterm.cr"
  CW::Box.new parent: dock, top: 2, left: 2, content: "widget.cr"
end
