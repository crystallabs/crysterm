# The same hello, the Qt shape: a `MainWindow` frame (menu bar + status bar)
# with a layout-managed central widget — no absolute coordinates.
require "../../src/crysterm"

include Crysterm

window = Window.new title: "hello2"

win = Widget::MainWindow.new parent: window

menubar = Widget::MenuBar.new
win.menu_bar = menubar
menubar.add_menu("File").add_action("Quit") { window.quit }

status = Widget::StatusBar.new
win.status_bar = status
status.show_message "Ready — press q to quit"

# The central widget arranges its children with a layout engine; add or
# remove boxes and the arrangement just re-flows.
central = Widget::Box.new layout: Layout::VBox.new(spacing: 1)
win.central_widget = central

%w[Hello world !].each do |word|
  Widget::Box.new parent: central, parse_tags: true,
    content: "{center}{bold}#{word}{/bold}{/center}",
    style: Style.new(border: true)
end

window.exec
