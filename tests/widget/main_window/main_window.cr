# Example: Crysterm::Widget::MainWindow
#
# Minimal, self-contained example of a single MainWindow.
# Run it:     crystal run examples/widget/main_window/main_window.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run "MainWindow" do |window|
  window.stylesheet = "Box { color: #c0caf5; } MenuBar { background-color: #283457; } StatusBar { background-color: #283457; }"
  mw = MainWindow.new parent: window, top: 0, left: 0, width: "100%", height: "100%"
  mw.menu_bar = (mb = MenuBar.new)
  %w[File Edit View Help].each { |t| mb.add_menu t }
  dock = DockWidget.new title: " Project ", area: :left, dock_size: 22
  Widget::Box.new parent: dock, top: 0, left: 1, content: "src/\n  crysterm.cr\n  widget.cr\ndocs/\n  README.md"
  mw.add_dock dock
  mw.central_widget = Widget::Box.new(
    content: "{center}Editor — central widget{/center}", parse_tags: true,
    style: Style.new(border: true))
  mw.status_bar = (sb = StatusBar.new)
  sb.show_message "Ready"
  sb.add_permanent "Ln 1, Col 1"
end
