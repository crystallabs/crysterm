# Example: Crysterm::Widget::Menu
#
# Minimal, self-contained example of a single Menu.
# Run it:     crystal run examples/widget/menu/menu.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("Menu",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.5
    d.key :down, times: 3, dwell: 0.4
    d.key :up, times: 3, dwell: 0.4
  }) do |screen|
  screen.stylesheet = "Menu { border: solid; color: #c0caf5; }"
  menu = Crysterm::Widget::Menu.new parent: screen, top: "center", left: "center"
  %w[New Open Save Quit].each { |t| menu.add_action t }
end
