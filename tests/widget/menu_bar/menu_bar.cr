# Example: Crysterm::Widget::MenuBar
#
# Minimal, self-contained example of a single MenuBar.
# Run it:     crystal run examples/widget/menu_bar/menu_bar.cr
# Maintained by tools/manage-examples.cr
require "../example"

Crysterm::WidgetExample.run("MenuBar",
  script: ->(d : Crysterm::WidgetExample::Driver) {
    d.hold 0.6
    # Open File menu, then close it.
    d.act(dwell: 1.2) { |s| s.children.each { |c| c.toggle(0) if c.is_a?(Crysterm::Widget::MenuBar) } }
    d.act(dwell: 0.8) { |s| s.children.each { |c| c.toggle(0) if c.is_a?(Crysterm::Widget::MenuBar) } }
  }) do |screen|
  screen.stylesheet = "MenuBar { color: #c0caf5; } Menu { color: #c0caf5; }"
  mb = Crysterm::Widget::MenuBar.new parent: screen, top: 0, left: 0, width: "100%"
  file = mb.add_menu "File"
  %w[New Open Save Quit].each { |t| file.add_action t }
  %w[Edit View Tools Help].each { |t| mb.add_menu t }
end
