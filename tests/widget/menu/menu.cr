# Example: Crysterm::Widget::Menu
#
# Minimal, self-contained example of a single Menu.
# Run it:     crystal run examples/widget/menu/menu.cr
# Maintained by tools/manage-examples.cr
require "../example"

include Crysterm
include Crysterm::Widgets

Crysterm::WidgetExample.run("Menu",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :down, times: 3, dwell: 0.4
    d.key :up, times: 3, dwell: 0.4
  }) do |window|
  window.stylesheet = "Menu { border: solid; color: #c0caf5; }"
  menu = Menu.new parent: window, top: "center", left: "center"
  %w[New Open Save Quit].each { |t| menu.add_action t }
end
