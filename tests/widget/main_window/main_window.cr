# Example: Crysterm::Widget::MainWindow
#
# Minimal, self-contained example of a single MainWindow.
# Run it:     crystal run tests/widget/main_window/main_window.cr
require "../example"

alias CT = Crysterm
alias CW = CT::Widgets

Crysterm::WidgetExample.run "MainWindow" do |window|
  window.stylesheet = "Box { color: #c0caf5; } MenuBar { background-color: #283457; } StatusBar { background-color: #283457; }"
  mw = CW::MainWindow.new parent: window
  mw.menu_bar = (mb = CW::MenuBar.new)
  %w[File Edit View Help].each { |t| mb.add_menu t }
  dock = CW::DockWidget.new title: " Project ", area: :left, dock_size: 22
  CW::Box.new parent: dock, top: 0, left: 1, content: "src/\n  crysterm.cr\n  widget.cr\ndocs/\n  README.md"
  mw.add_dock dock
  mw.central_widget = CW::Box.new(
    content: "{center}Editor — central widget{/center}", parse_tags: true,
    style: CT::Style.new(border: true))
  mw.status_bar = (sb = CW::StatusBar.new)
  sb.show_message "Ready"
  sb.add_permanent "Ln 1, Col 1"
end
